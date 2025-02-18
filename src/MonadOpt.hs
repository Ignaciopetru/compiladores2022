module MonadOpt where

import Control.Monad.State
import Lang
import Control.Monad

data StateOpt = StateOpt {
  opt :: Int,
  nenv :: [Name]
}

newtype Changes a = Changes { runChanges :: StateOpt -> (a, StateOpt) }

class Monad m => MonadOptimization m where
    -- Agrega el cambio al total de optimizaciones
    add :: Int -> m ()
    -- Devuelve el total de optimizaciones
    total :: m Int
    update :: Name -> m ()
    getNEnv :: m [Name]

instance Monad Changes where
    return x = Changes (\i -> (x, i))
    m >>= f = Changes (\i -> let (x, i') = runChanges m i in runChanges (f x) i')

instance Functor Changes where
    fmap = liftM

instance Applicative Changes where
    pure  = return
    (<*>) = ap

instance MonadOptimization Changes where
    add x = Changes (\i -> ((), i {opt = x + opt i}))
    total = Changes (\i -> (opt i, i))
    update n = Changes (\i -> ((), i {nenv = n : nenv i}))
    getNEnv = Changes (\i -> ((nenv i), i))
{-

multipleFoldings :: MonadOptimization m => TTerm -> m ()
-- Caso base no se que hacer: multipleFoldings ??? = ???
multipleFoldings (V _ _) = return ()
multipleFoldings (Const _ _) = return ()
multipleFoldings t = constantFolding t >>= \t' -> multipleFoldings t'

constantFolding :: MonadOptimization m => TTerm -> m TTerm
constantFolding (App inf l r) = return (App inf (constantFolding l) (constantFolding r)) -- Puede ser necesario hacer constantFolding sobre l y r y sumar los valores
constantFolding (IfZ inf (Const _ (CNat 0)) true false) = do add 1
                                                             return true -- O puede hacer un add sobre la evaluacion de true
constantFolding (IfZ inf (Const _ (CNat _)) true false) = do add 1
                                                             return false


class (MonadState Int m) => MonadOpt m where

add :: MonadOpt m => m ()
add = modify (\s -> s + 1)

type OPT = (StateT Int)

-- | Esta es una instancia vacía, ya que 'MonadFD4' no tiene funciones miembro.
instance MonadOpt OPT
-}