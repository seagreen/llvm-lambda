{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving, FlexibleContexts #-}

module Codegen where

import Data.Char (ord)
import Data.ByteString (ByteString)
import Data.Map (Map, (!))
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Control.Monad.State
import Control.Monad.Identity
import Data.Word (Word32)

import LLVM.AST hiding (value, index, expected, args)
import LLVM.AST.DataLayout
import LLVM.AST.FunctionAttribute
import qualified LLVM.AST.IntegerPredicate as IPred
import qualified LLVM.AST.Global as G
import qualified LLVM.AST.Constant as C
import LLVM.AST.AddrSpace (AddrSpace(AddrSpace))
import LLVM.AST.Linkage (Linkage(Private))
import LLVM.Context
import LLVM.Module hiding (Module)

import LowLevel
import Fresh
import LibCDefs

generate :: Prog -> IO ByteString
generate prog = withContext $ \ctx -> withModuleFromAST ctx (genModule prog) moduleLLVMAssembly


-- sample :: IO ByteString
-- sample = withContext $ \ctx -> withModuleFromAST ctx ir moduleLLVMAssembly
--   where
--     ir :: Module
--     ir = let globals = map (GlobalDefinition . snd) . Map.toList . defs . execFreshCodegen $ buildModule
--            in defaultModule { moduleName = "main", moduleDefinitions = globals }
--
--     addDefs :: FreshCodegen ()
--     addDefs = do
--       defineFmtString
--       defineGuard
--       defineCheckArity
--       finishFunction malloc
--       finishFunction exit
--       finishFunction printf
--
--     buildFunction :: FreshCodegen Name
--     buildFunction = do
--       let envParam = (star (star intType), Name "env")
--       let argParam = (star intType, Name "x")
--
--       -- get a refernece to the environment
--       let env = uncurry LocalReference envParam
--
--       -- get a value from the environment
--       valueBox <- getFromEnv env 0
--       value <- getNum valueBox
--
--       arg <- getNum (uncurry LocalReference argParam)
--       added <- doInstruction intType $ Add False False value arg []
--       result <- allocNumber added
--
--       finishBlock (Name "entry") (Do $ Ret (Just result) [])
--
--       let functionDef = defParams
--             { G.name = Name "increment"
--             , G.parameters = ([uncurry Parameter envParam [], uncurry Parameter argParam []], False)
--             }
--       finishFunction functionDef
--
--       return $ G.name functionDef
--
--     buildModule :: FreshCodegen ()
--     buildModule = do
--       addDefs
--
--       loc <- allocNumber . ConstantOperand . C.Int 32 $ 319
--
--       funcName <- inNewScope buildFunction
--
--       clos <- allocClosure funcName [loc]
--
--       result <- callClosure clos [loc]
--       printOperand result
--
--       finishBlock (Name "entry") (Do $ Ret Nothing [])
--       finishFunction functionDefaults
--         { G.name = Name "main"
--         , G.parameters = ([], False)
--         , G.returnType = VoidType
--         }


newtype CodegenT m a =
  CodegenT { codegenState :: StateT CodegenState m a }
  deriving (Functor, Applicative, Monad, MonadState CodegenState)

type Env = Map String Operand

data CodegenState = CodegenState
  { defs :: Map Name Global
  , blockName :: Maybe Name
  , blocks :: [BasicBlock]
  , instructions :: [Named Instruction]
  , environment :: Env
  }

type Codegen = CodegenT Identity

execCodegen :: Codegen a -> CodegenState -> CodegenState
execCodegen = execState . codegenState

modifyEnvironment :: MonadState CodegenState m => (Env -> Env) -> m ()
modifyEnvironment f = modify $ \s -> s { environment = f . environment $ s }

addInstruction :: MonadState CodegenState m => Named Instruction -> m ()
addInstruction instr = modify $ \s -> s { instructions = instr : instructions s }

type FreshCodegen = FreshT Codegen

execFreshCodegen :: FreshCodegen a -> CodegenState
execFreshCodegen = flip execCodegen emptyState . flip evalFreshT Map.empty
  where
    emptyState = CodegenState { defs=Map.empty, blockName=Nothing, blocks=[], instructions=[], environment=Map.empty }


pointerBits :: Word32
pointerBits = fst $ pointerLayouts (defaultDataLayout LittleEndian) ! AddrSpace 0

closureTag, intTag :: Operand
closureTag = ConstantOperand $ C.Int 32 0
intTag     = ConstantOperand $ C.Int 32 1


defineGuard :: FreshCodegen ()
defineGuard = do
  let actualParam   = (star intType, Name "actual")
  let expectedParam = (intType, Name "expected")

  errBlock <- uniqueName "err"
  okBlock <- uniqueName "ok"

  uniqueName "entry" >>= startBlock
  actualValue <- doInstruction intType $ Load True (uncurry LocalReference actualParam) Nothing 0 []
  notEq <- doInstruction boolType $ ICmp IPred.NE actualValue (uncurry LocalReference expectedParam) []
  finishBlock $ Do $ CondBr notEq errBlock okBlock []

  startBlock errBlock
  addInstruction $ Do $ callGlobal exit [ConstantOperand (C.Int 32 1)]
  finishBlock $ Do $ Unreachable []

  startBlock okBlock
  finishBlock $ Do $ Ret Nothing []

  defineFunction functionDefaults
    { G.name = Name "guard"
    , G.parameters = ([uncurry Parameter actualParam [], uncurry Parameter expectedParam []], False)
    , G.returnType = VoidType
    , G.functionAttributes = [Right InlineHint]
    }


defineCheckArity :: FreshCodegen ()
defineCheckArity = do
  let closure = (star intType, Name "closure")
  let numArgs = (intType, Name "numArgs")

  errBlock <- uniqueName "err"
  okBlock <- uniqueName "ok"

  uniqueName "entry" >>= startBlock
  arityLoc <- doInstruction (star intType) (arrayAccess (uncurry LocalReference closure) 1)
  arity <- doInstruction intType $ Load True arityLoc Nothing 0 []
  notEq <- doInstruction boolType $ ICmp IPred.NE arity (uncurry LocalReference numArgs) []
  finishBlock $ Do $ CondBr notEq errBlock okBlock []

  startBlock errBlock
  addInstruction $ Do $ callGlobal exit [ConstantOperand (C.Int 32 2)]
  finishBlock $ Do $ Unreachable []

  startBlock okBlock
  finishBlock $ Do $ Ret Nothing []

  defineFunction functionDefaults
    { G.name = Name "checkArity"
    , G.parameters = ([uncurry Parameter closure [], uncurry Parameter numArgs []], False)
    , G.returnType = VoidType
    , G.functionAttributes = [Right InlineHint]
    }


genModule :: Prog -> Module
genModule (Prog progDefs expr) = defaultModule { moduleName = "main", moduleDefinitions = allDefs }
  where
    allDefs :: [Definition]
    allDefs = map (GlobalDefinition . snd) . Map.toList . defs . execFreshCodegen $ buildModule

    declareDef :: Def -> FreshCodegen ()
    declareDef (ClosureDef name envName argNames _) =
      modify $ \s -> s { defs = Map.insert defName emptyDef (defs s) }
      where
        defName = mkName name
        argParam argName = Parameter (star intType) (mkName argName) []
        params = Parameter (star (star intType)) (mkName envName) [] : map argParam argNames
        emptyDef = defParams { G.name = defName , G.parameters = (params , False) }

    addGlobalDef :: Def -> FreshCodegen ()
    addGlobalDef (ClosureDef name envName argNames body) = do
      uniqueName "entry" >>= startBlock
      let env = LocalReference (star (star intType)) (mkName envName)
      let mkArg argName = LocalReference (star intType) (mkName argName)

      -- put all the arguments into the environment
      oldEnv <- gets environment
      modifyEnvironment $ Map.insert envName env
      let insertions = zipWith Map.insert argNames (map mkArg argNames)
      mapM_ modifyEnvironment insertions

      -- generate the function code
      result <- synthExpr body

      -- reset the environment
      modifyEnvironment $ const oldEnv

      finishBlock (Do $ Ret (Just result) [])
      finishFunction $ mkName name

    buildModule :: FreshCodegen ()
    buildModule = do
      addDefs
      -- Run codegen for definitions
      mapM_ declareDef progDefs
      mapM_ addGlobalDef progDefs

      -- Run codegen for main
      uniqueName "entry" >>= startBlock
      result <- synthExpr expr

      -- Print result
      printOperand result

      finishBlock (Do $ Ret Nothing [])
      defineFunction functionDefaults
        { G.name = Name "main"
        , G.parameters = ([], False)
        , G.returnType = VoidType
        }

    addDefs :: FreshCodegen ()
    addDefs = do
      defineFmtString
      defineGuard
      defineCheckArity
      defineFunction malloc
      defineFunction exit
      defineFunction printf


defineFmtString :: FreshCodegen ()
defineFmtString = modify $ \s -> s { defs = Map.insert name global (defs s) }
  where
    name = Name "fmt"
    global = globalVariableDefaults
      { G.name = name
      , G.linkage = Private
      , G.isConstant = True
      , G.type' = ArrayType 4 charType
      , G.initializer = Just . C.Array charType . mkString $ "%d\n\NUL"
      }
    mkString = map (C.Int 8 . fromIntegral . ord)


printOperand :: Operand -> FreshCodegen ()
printOperand loc = do
  value <- getNum loc
  let fmtRef = C.GlobalReference (PointerType (ArrayType 4 charType) (AddrSpace 0)) (Name "fmt")
  let fmtArg = ConstantOperand $ C.GetElementPtr True fmtRef [C.Int 32 0, C.Int 32 0]
  addInstruction $ Do $ callGlobal printf [fmtArg, value]
  return ()


defParams :: Global
defParams = functionDefaults { G.returnType = star intType }


cast :: Type -> Operand -> FreshCodegen Operand
cast typ input = doInstruction typ $ BitCast input typ []


arrayAccess :: Operand -> Integer -> Instruction
arrayAccess array index = GetElementPtr True array [ConstantOperand $ C.Int pointerBits index] []


--         i32*                     i32
getNum :: Operand -> FreshCodegen Operand
getNum loc = do
  checkTag loc intTag
  valueLoc <- doInstruction (star intType) $ GetElementPtr True loc [ConstantOperand (C.Int pointerBits 1)] []
  doInstruction intType $ Load True valueLoc Nothing 0 []


allocNumber :: Operand -> FreshCodegen Operand
allocNumber num = do
  -- malloc a number
  mem <- doInstruction (star charType) $ callGlobal malloc [ConstantOperand $ C.Int 64 8]
  loc <- cast (star intType) mem
  -- set the type tag
  addInstruction $ Do $ Store True loc intTag Nothing 0 []
  -- set the value
  valueLoc <- doInstruction (star intType) $ arrayAccess loc 1
  addInstruction $ Do $ Store True valueLoc num Nothing 0 []
  -- return the memory location
  return loc


checkTag :: Operand -> Operand -> FreshCodegen ()
checkTag actual expected = do
  guardDef <- findGuard
  addInstruction $ Do $ callGlobal guardDef [actual, expected]
  where
    findGuard = gets $ fromMaybe (error "no guard definition found") . Map.lookup (Name "guard") . defs


checkArity :: Operand -> Integer -> FreshCodegen ()
checkArity clos numArgs = do
  def <- findDef
  addInstruction $ Do $ callGlobal def [clos, ConstantOperand (C.Int 32 numArgs)]
  where
    findDef = gets $ fromMaybe (error "no checkArity definition found") . Map.lookup (Name "checkArity") . defs


callClosure :: Operand -> [Operand] -> FreshCodegen Operand
callClosure clos args = do
  -- make sure we've got a closure
  checkTag clos closureTag
  let arity = length args
  checkArity clos (fromIntegral arity)
  -- find where the pointer array starts
  array <- doInstruction intType (arrayAccess clos 2) >>= cast (star (star intType))
  -- get the function
  let functionType = FunctionType (star intType) (star (star intType) : replicate arity (star intType)) False
  funcPtr <- doInstruction (star intType) (arrayAccess array 0) >>= cast (star (star functionType))
  func <- doInstruction (star functionType) $ Load True funcPtr Nothing 0 []
  -- get the environment
  env <- doInstruction (star (star intType)) $ arrayAccess array 1
  -- call the function
  let cc = G.callingConvention defParams
      retAttrs = G.returnAttributes defParams
      fAttrs = G.functionAttributes defParams
  doInstruction (star intType) $ Call Nothing cc retAttrs (Right func) (zip (env:args) $ repeat []) fAttrs []


allocClosure :: Name -> [Operand] -> FreshCodegen Operand
allocClosure funcName values = do
  -- need enough memory for two ints and then an array of pointers
  -- all sizes are in bytes
  let pointerBytes = fromIntegral pointerBits `quot` 8
  let closureSize = ConstantOperand . C.Int 64 . fromIntegral $ 8 + pointerBytes * length values
  loc <- doInstruction (star charType) (callGlobal malloc [closureSize]) >>= cast (star intType)
  -- set the type tag
  addInstruction $ Do $ Store True loc closureTag Nothing 0 []
  -- set number of args
  arityLoc <- doInstruction (star intType) $ arrayAccess loc 1
  arity <- defArity
  addInstruction $ Do $ Store True arityLoc (ConstantOperand (C.Int 32 arity)) Nothing 0 []
  -- get a reference to the funcPtr
  let argTypes = star (star intType) : replicate (fromIntegral arity) (star intType)
  let funcRef = C.GlobalReference (star (FunctionType (star intType) argTypes False)) funcName
  funcPtr <- cast (star intType) $ ConstantOperand funcRef
  -- fill in the array of pointers
  arrayLoc <- doInstruction (star intType) (arrayAccess loc 2) >>= cast (star (star intType))
  storePtr arrayLoc (funcPtr, 0)
  -- fill in the values in the array
  mapM_ (storePtr arrayLoc) (zip values [1..])
  return loc
  where
    defArity :: FreshCodegen Integer
    defArity = do
      global <- gets $ \s -> fromMaybe (error ("Function not defined: " ++ show funcName)) $ Map.lookup funcName (defs s)
      return . subtract 1 . fromIntegral . length . fst . G.parameters $ global
    storePtr :: Operand -> (Operand, Integer) -> FreshCodegen ()
    storePtr arrayLoc (ptr, index) = do
      wherePut <- doInstruction (star (star intType)) $ arrayAccess arrayLoc index
      addInstruction $ Do $ Store True wherePut ptr Nothing 0 []


getFromEnv :: Operand -> Integer -> FreshCodegen Operand
getFromEnv env index = do
  loc <- doInstruction (star (star intType)) $ arrayAccess env index
  doInstruction (star intType) $ Load True loc Nothing 0 []


type IntBinOp = Bool -> Bool -> Operand -> Operand -> InstructionMetadata -> Instruction

numBinOp :: Expr -> Expr -> IntBinOp -> FreshCodegen Operand
numBinOp a b op = do
  aValue <- synthExpr a >>= getNum
  bValue <- synthExpr b >>= getNum
  resultValue <- doInstruction intType $ op False False aValue bValue []
  allocNumber resultValue


synthIf0 :: Expr -> Expr -> Expr -> FreshCodegen Operand
synthIf0 c t f = do
  condInt <- synthExpr c >>= getNum
  condValue <- doInstruction boolType $ ICmp IPred.EQ condInt (ConstantOperand $ C.Int 32 0) []
  trueLabel <- uniqueName "trueBlock"
  falseLabel <- uniqueName "falseBlock"
  exitLabel <- uniqueName "ifExit"
  finishBlock $ Do $  CondBr condValue trueLabel falseLabel []
  -- Define the true block
  startBlock trueLabel
  trueValue <- synthExpr t
  finishBlock $ Do $ Br exitLabel []
  -- Define the false block
  startBlock falseLabel
  falseValue <- synthExpr f
  finishBlock $ Do $ Br exitLabel []
  -- get the correct output
  startBlock exitLabel
  doInstruction (star intType) $ Phi (star intType) [(trueValue, trueLabel), (falseValue, falseLabel)] []


synthExpr :: Expr -> FreshCodegen Operand
synthExpr (Num n) = allocNumber . ConstantOperand . C.Int 32 . fromIntegral $ n

synthExpr (Plus a b) = numBinOp a b Add

synthExpr (Minus a b) = numBinOp a b Sub

synthExpr (Mult a b) = numBinOp a b Mul

synthExpr (Divide a b) = numBinOp a b (const SDiv)

synthExpr (If0 c t f) = synthIf0 c t f

synthExpr (Let name binding body) = do
  oldEnv <- gets environment
  bindingName <- synthExpr binding
  modifyEnvironment $ Map.insert name bindingName
  resultName <- synthExpr body
  modifyEnvironment $ const oldEnv
  return resultName

synthExpr (Ref name) = do
  env <- gets environment
  return . fromMaybe (error ("Unbound name: " ++ name)) $ Map.lookup name env

synthExpr (App funcName argExprs) = do
  -- find the function in the list of definitions
  global <- gets $ \s -> fromMaybe (error ("Function not defined: " ++ funcName)) $ Map.lookup (mkName funcName) (defs s)
  -- call the function
  args <- mapM synthExpr argExprs
  doInstruction (star intType) $ callGlobal global args

synthExpr (AppClos closExpr argExprs) = do
  clos <- synthExpr closExpr
  args <- mapM synthExpr argExprs
  callClosure clos args

synthExpr (NewClos closName bindings) = do
  args <- mapM synthExpr bindings
  allocClosure (mkName closName) args

synthExpr (GetEnv closExpr index) = do
  clos <- synthExpr closExpr
  getFromEnv clos index


doInstruction :: Type -> Instruction -> FreshCodegen Operand
doInstruction typ instr = do
  myName <- fresh
  addInstruction $ myName := instr
  return $ LocalReference typ myName


startBlock :: Name -> FreshCodegen ()
startBlock name = do
  currentName <- gets blockName
  case currentName of
    Nothing -> modify $ \s -> s { blockName = Just name }
    (Just n) -> error $ "Cant start block " ++ show name ++ "! Already working on block " ++ show n


finishBlock :: Named Terminator -> FreshCodegen ()
finishBlock term = do
  name <- gets $ fromMaybe (error "No block started!") . blockName
  instrs <- gets $ reverse . instructions
  let block = BasicBlock name instrs term
  modify $ \s -> s { blockName = Nothing, blocks = block : blocks s, instructions = [] }


defineFunction :: Global -> FreshCodegen ()
defineFunction emptyDef = do
  definedBlocks <- gets $ reverse . blocks
  let def = emptyDef { G.basicBlocks = definedBlocks }
  modify $ \s -> s { blocks = [], defs = Map.insert (G.name def) def (defs s) }


finishFunction :: Name -> FreshCodegen ()
finishFunction name = do
  emptyDef <- gets $ fromMaybe (error ("No definition to finish: " ++ show name)) . Map.lookup name . defs
  defineFunction emptyDef


inNewScope :: FreshCodegen a -> FreshCodegen a
inNewScope dirtyOps = do
  oldBlocks <- gets blocks
  oldInstructions <- gets instructions
  modify $ \s -> s { blocks = [], instructions = [] }
  result <- dirtyOps
  modify $ \s -> s { blocks = oldBlocks, instructions = oldInstructions }
  return result


callGlobal :: Global -> [Operand] -> Instruction
callGlobal func argOps = Call Nothing cc retAttrs fOp args fAttrs []
  where
    cc = G.callingConvention func
    retAttrs = G.returnAttributes func
    fAttrs = G.functionAttributes func
    args = map (flip (,) []) argOps
    fOp = Right $ ConstantOperand $ C.GlobalReference ptrType (G.name func)
    ptrType = PointerType (FunctionType retType argTypes varArgs) (AddrSpace 0)
    retType = G.returnType func
    argTypes = map typeOf . fst . G.parameters $ func
    typeOf (Parameter typ _ _) = typ
    varArgs = snd . G.parameters $ func
