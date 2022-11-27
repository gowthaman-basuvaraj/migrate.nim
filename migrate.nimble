# Package

version       = "2.0.0"
author        = "Gowthaman Basuvaraj"
description   = "A database migration tool written in Nim. Based on work by Euan T"
license       = "BSD3"

bin = @["migrate"]

# Dependencies

requires "nim >= 0.14.0", "docopt >= 0.6.2"
