{-# LANGUAGE RecordWildCards #-}

{-|
Module      : Main
Description : Compilador de FD4.
Copyright   : (c) Mauro Jaskelioff, Guido Martínez, 2020.
License     : GPL-3
Maintainer  : mauro@fceia.unr.edu.ar
Stability   : experimental

-}

module Main where

import System.Console.Haskeline ( defaultSettings, getInputLine, runInputT, InputT )
import Control.Monad.Catch (MonadMask)

--import Control.Monad
import Control.Monad.Trans
import Data.List (nub, isPrefixOf, intercalate )
import Data.Char ( isSpace )
import Control.Exception ( catch , IOException )
import System.IO ( hPrint, stderr, hPutStrLn )
import Data.Maybe ( fromMaybe, maybeToList )

import System.Exit ( exitWith, ExitCode(ExitFailure) )
import Options.Applicative

import Global
import Errors
import Lang
import Parse ( P, tm, program, declOrTm, runP )
import Elab ( elab, elabDecl, elabDeclType, elabTermType )
import Eval ( eval )
import CEK ( evalCEK )
import PPrint ( pp , ppTy, ppDecl )
import MonadFD4
import TypeChecker ( tc, tcDecl )
import Bytecompile
import Optimize

prompt :: String
prompt = "FD4> "



-- | Parser de banderas
parseMode :: Parser (Mode,Bool)
parseMode = (,) <$>
      (flag' Typecheck ( long "typecheck" <> short 't' <> help "Chequear tipos e imprimir el término")
      <|> flag' InteractiveTypecheck (long "interactiveTypecheck" <> short 'Ǽ' <> help "Chequear tipos de manera interactiva")
      <|> flag' InteractiveCEK (long "interactiveCEK" <> short 'k' <> help "Ejecutar interactivamente en la CEK")
      <|> flag' Bytecompile (long "bytecompile" <> short 'm' <> help "Compilar a la BVM")
      <|> flag' RunVM (long "runVM" <> short 'r' <> help "Ejecutar bytecode en la BVM")
      <|> flag Interactive Interactive ( long "interactive" <> short 'i' <> help "Ejecutar en forma interactiva")
  -- <|> flag' CC ( long "cc" <> short 'c' <> help "Compilar a código C")
  -- <|> flag' Canon ( long "canon" <> short 'n' <> help "Imprimir canonicalización")
  -- <|> flag' Assembler ( long "assembler" <> short 'a' <> help "Imprimir Assembler resultante")
  -- <|> flag' Build ( long "build" <> short 'b' <> help "Compilar")
      )
   -- <*> pure False
   -- reemplazar por la siguiente línea para habilitar opción
      <*> flag False True (long "optimize" <> short 'o' <> help "Optimizar código")

-- | Parser de opciones general, consiste de un modo y una lista de archivos a procesar
parseArgs :: Parser (Mode,Bool, [FilePath])
parseArgs = (\(a,b) c -> (a,b,c)) <$> parseMode <*> many (argument str (metavar "FILES..."))

main :: IO ()
main = execParser opts >>= go
  where
    opts = info (parseArgs <**> helper)
      ( fullDesc
     <> progDesc "Compilador de FD4"
     <> header "Compilador de FD4 de la materia Compiladores 2022" )

    go :: (Mode,Bool,[FilePath]) -> IO ()
    go (Interactive,opt,files) =
              runOrFail (Conf opt Interactive) (runInputT defaultSettings (repl files))
    go (InteractiveCEK, opt, files) =
              runOrFail (Conf opt InteractiveCEK) (runInputT defaultSettings (repl files))
    go (InteractiveTypecheck, opt, files) =
              runOrFail (Conf opt InteractiveTypecheck) (runInputT defaultSettings (repl files))
    go (Bytecompile, opt, files) =
              runOrFail (Conf opt Bytecompile) $ mapM_ compileFile files
    go (RunVM, opt, files) =
              runOrFail (Conf opt RunVM) $ mapM_ compileFile files
    go (m,opt, files) =
              runOrFail (Conf opt m) $ mapM_ compileFile files

runOrFail :: Conf -> FD4 a -> IO a
runOrFail c m = do
  r <- runFD4 m c
  case r of
    Left err -> do
      liftIO $ hPrint stderr err
      exitWith (ExitFailure 1)
    Right v -> return v

repl :: (MonadFD4 m, MonadMask m) => [FilePath] -> InputT m ()
repl args = do
       lift $ catchErrors $ mapM_ compileFile args
       s <- lift get
       when (inter s) $ liftIO $ putStrLn
         (  "Entorno interactivo para FD4.\n"
         ++ "Escriba :? para recibir ayuda.")
       loop
  where loop = do
           minput <- getInputLine prompt
           case minput of
               Nothing -> return ()
               Just "" -> loop
               Just x -> do
                       c <- liftIO $ interpretCommand x
                       b <- lift $ catchErrors $ handleCommand c
                       maybe loop (`when` loop) b

loadFile ::  MonadFD4 m => FilePath -> m [SDecl STerm]

loadFile f = do
    let filename = reverse(dropWhile isSpace (reverse f))
    x <- liftIO $ catch (readFile filename)
               (\e -> do let err = show (e :: IOException)
                         hPutStrLn stderr ("No se pudo abrir el archivo " ++ filename ++ ": " ++ err)
                         return "")
    setLastFile filename
    parseIO filename program x


checkAndStore :: MonadFD4 m => Decl Term -> m (Decl TTerm)
checkAndStore d = do t' <- tcDecl d
                     addDecl t'
                     return t'
                     

compileFile ::  MonadFD4 m => FilePath -> m ()
compileFile f = do
    mode <- getMode
    case mode of
      Bytecompile -> do
                    setInter False
                    printFD4 ("Abriendo "++f++"...")
                    lf <- loadFile f

                    mbl <- mapM elabDeclType lf
                    mbl2 <- mapM elabDecl mbl
                    let decls = concat (map maybeToList mbl2)
                    typedDecls <- mapM checkAndStore decls
                    printFD4 (show typedDecls)

                    comp <- bytecompileModule typedDecls
                    printFD4 (showBC comp)
                    liftIO $ bcWrite comp "file.bc"
                    -- map read $ words "1 2 3 4 5"
      RunVM -> do
                  lf <- liftIO $ bcRead f
                  runBC lf
      _ -> do 
                    i <- getInter
                    setInter False
                    printFD4 ("Abriendo "++f++"...")
                    decls <- loadFile f
                    mapM_ handleDecl decls
                    setInter i

parseIO ::  MonadFD4 m => String -> P a -> String -> m a
parseIO filename p x = case runP p x filename of
                  Left e  -> throwError (ParseErr e)
                  Right r -> return r

handleDecl ::  MonadFD4 m => SDecl STerm -> m ()
handleDecl d = do
        m <- getMode
        case m of
          Interactive -> do
                            a <- typecheckDecl d
                            (case a of
                              Nothing -> return ()
                              Just (Decl p x tt) -> 
                                do te <- eval tt
                                   addDecl (Decl p x te))
          Typecheck -> do
                          f <- getLastFile
                          printFD4 ("Chequeando tipos de "++f)
                          td <- typecheckDecl d
                          (case td of
                            Nothing -> return ()
                            Just tf ->
                              -- hay que hacer esto en todos los otros casos de ejecución, para saber so optimizar o no.
                               do opt <- getOpt
                                  let td' = if opt then optimize tf else tf
                                  addDecl td'
                                  ppterm <- ppDecl td'
                                  printFD4 ppterm)
          InteractiveCEK -> do
                              a <- typecheckDecl d
                              (case a of
                                Nothing -> return ()
                                Just (Decl p x tt) -> 
                                  do te <- evalCEK tt
                                     addDecl (Decl p x te))
          _ -> pure () -- Para los casos que no son necesarios considerar. Idem mas abajo


typecheckDecl :: MonadFD4 m => SDecl STerm -> m (Maybe (Decl TTerm))
typecheckDecl dec = do  decT <- elabDeclType dec 
                        t <- elabDecl decT
                        case t of
                          Nothing -> return Nothing
                          Just tt -> do t' <- tcDecl tt
                                        return (Just t')



data Command = Compile CompileForm
             | PPrint String
             | Type String
             | Reload
             | Browse
             | Quit
             | Help
             | Noop

data CompileForm = CompileInteractive  String
                 | CompileFile         String

data InteractiveCommand = Cmd [String] String (String -> Command) String

-- | Parser simple de comando interactivos
interpretCommand :: String -> IO Command
interpretCommand x
  =  if ":" `isPrefixOf` x then
       do  let  (cmd,t')  =  break isSpace x
                t         =  dropWhile isSpace t'
           --  find matching commands
           let  matching  =  filter (\ (Cmd cs _ _ _) -> any (isPrefixOf cmd) cs) commands
           case matching of
             []  ->  do  putStrLn ("Comando desconocido `" ++ cmd ++ "'. Escriba :? para recibir ayuda.")
                         return Noop
             [Cmd _ _ f _]
                 ->  do  return (f t)
             _   ->  do  putStrLn ("Comando ambigüo, podría ser " ++
                                   intercalate ", " ([ head cs | Cmd cs _ _ _ <- matching ]) ++ ".")
                         return Noop

     else
       return (Compile (CompileInteractive x))

commands :: [InteractiveCommand]
commands
  =  [ Cmd [":browse"]      ""        (const Browse) "Ver los nombres en scope",
       Cmd [":load"]        "<file>"  (Compile . CompileFile)
                                                     "Cargar un programa desde un archivo",
       Cmd [":print"]       "<exp>"   PPrint          "Imprime un término y sus ASTs sin evaluarlo",
       Cmd [":reload"]      ""        (const Reload)         "Vuelve a cargar el último archivo cargado",
       Cmd [":type"]        "<exp>"   Type           "Chequea el tipo de una expresión",
       Cmd [":quit",":Q"]        ""        (const Quit)   "Salir del intérprete",
       Cmd [":help",":?"]   ""        (const Help)   "Mostrar esta lista de comandos" ]

helpTxt :: [InteractiveCommand] -> String
helpTxt cs
  =  "Lista de comandos:  Cualquier comando puede ser abreviado a :c donde\n" ++
     "c es el primer caracter del nombre completo.\n\n" ++
     "<expr>                  evaluar la expresión\n" ++
     "let <var> = <expr>      definir una variable\n" ++
     unlines (map (\ (Cmd c a _ d) ->
                   let  ct = intercalate ", " (map (++ if null a then "" else " " ++ a) c)
                   in   ct ++ replicate ((24 - length ct) `max` 2) ' ' ++ d) cs)

-- | 'handleCommand' interpreta un comando y devuelve un booleano
-- indicando si se debe salir del programa o no.
handleCommand ::  MonadFD4 m => Command  -> m Bool
handleCommand cmd = do
   s@GlEnv {..} <- get
   case cmd of
       Quit   ->  return False
       Noop   ->  return True
       Help   ->  printFD4 (helpTxt commands) >> return True
       Browse ->  do  printFD4 (unlines (reverse (nub (map declName glb))))
                      return True
       Compile c ->
                  do  case c of
                          CompileInteractive e -> compilePhrase e
                          CompileFile f        -> compileFile f
                      return True
       Reload ->  eraseLastFileDecls >> (getLastFile >>= compileFile) >> return True
       PPrint e   -> printPhrase e >> return True
       Type e    -> typeCheckPhrase e >> return True

compilePhrase ::  MonadFD4 m => String -> m ()
compilePhrase x = do
    dot <- parseIO "<interactive>" declOrTm x
    case dot of
      Left d  -> handleDecl d
      Right t -> handleTerm t

handleTerm ::  MonadFD4 m => STerm -> m ()
handleTerm t = do
         ty <- elabTermType t
         t' <- elab ty
         s <- get
         tt <- tc t' (tyEnv s)
         m <- getMode
         case m of
           Interactive -> do te <- eval tt
                             ppte <- pp te
                             printFD4 (ppte ++ " : " ++ ppTy (getTy tt))
           InteractiveCEK -> do te <- evalCEK tt
                                ppte <- pp te
                                printFD4 (ppte ++ " : " ++ ppTy (getTy tt))
           InteractiveTypecheck -> do 
                            tpp <- pp tt
                            printFD4 tpp 
           _ -> pure ()
 
printPhrase   :: MonadFD4 m => String -> m ()
printPhrase x =
  do
    x' <- parseIO "<interactive>" tm x
    ty <- elabTermType x'
    ex <- elab ty
    tyenv <- gets tyEnv
    tex <- tc ex tyenv
    t  <- case x' of
           (SV p f) -> fromMaybe tex <$> lookupDecl f
           _       -> return tex
    printFD4 "STerm:"
    printFD4 (show x')
    printFD4 "TTerm:"
    printFD4 (show t)

typeCheckPhrase :: MonadFD4 m => String -> m ()
typeCheckPhrase x = do
         t <- parseIO "<interactive>" tm x
         tyt <- elabTermType t
         t' <- elab tyt
         s <- get
         tt <- tc t' (tyEnv s)
         let ty = getTy tt
         printFD4 (ppTy ty)
