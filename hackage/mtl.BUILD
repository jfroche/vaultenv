load("@io_tweag_rules_haskell//haskell:haskell.bzl", "haskell_library")

haskell_library(
  name = "mtl",
  visibility = ["//visibility:public"],
  srcs = [
    "Control/Monad/Cont.hs",
    "Control/Monad/Error.hs",
    "Control/Monad/Except.hs",
    "Control/Monad/Identity.hs",
    "Control/Monad/List.hs",
    "Control/Monad/Reader.hs",
    "Control/Monad/RWS.hs",
    "Control/Monad/State.hs",
    "Control/Monad/Trans.hs",
    "Control/Monad/Writer.hs",
    "Control/Monad/Cont/Class.hs",
    "Control/Monad/Error/Class.hs",
    "Control/Monad/Reader/Class.hs",
    "Control/Monad/RWS/Class.hs",
    "Control/Monad/RWS/Lazy.hs",
    "Control/Monad/RWS/Strict.hs",
    "Control/Monad/State/Class.hs",
    "Control/Monad/State/Lazy.hs",
    "Control/Monad/State/Strict.hs",
    "Control/Monad/Writer/Class.hs",
    "Control/Monad/Writer/Lazy.hs",
    "Control/Monad/Writer/Strict.hs",
  ],
  deps = [
  ],
  prebuilt_dependencies = [
    "base",
    "transformers",
  ],
  compiler_flags = [
    "-XFlexibleInstances",
    "-XFunctionalDependencies",
    "-XMultiParamTypeClasses",
    "-XUndecidableInstances",
  ],
)