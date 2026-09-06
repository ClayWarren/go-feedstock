# Benign native Windows ARM64 DLL export check

This personal-fork diagnostic uses ordinary C data and a function. It compares
DLLs with and without explicit exports using Microsoft LINK and LLD, verifies
ARM64 PE headers, inspects export tables, and runs a native C consumer that loads
each DLL. The consumer requires the exported value 73 and function result 42.

The conda Clang and Visual Studio activation package pins match the compiler
packages recorded by CGo validation run 33999433199. This check does not build Go,
run its test suite, edit binaries, or construct malformed objects. It proves a
toolchain export behavior, not the outcome of any Go regression test.

The registered CGo workflow path is reused only on this isolated branch so it
can be manually dispatched without changing the fork's default branch. The
commit carries `[skip ci]` to avoid the generated package build on push.
Only benign diagnostic artifacts are uploaded, never conda packages.
