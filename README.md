# BearVM

BearVM is a compact virtual machine that executes programs written in a simple, SSA-form intermediate language. It serves as one of the compilation targets for the Axe programming language, particularly in scenarios that emphasize high concurrency and parallelism.

## Purpose

BearVM is designed to support the execution needs of Axe, a language focused on expressing concurrent and parallel computations in a structured way. The VM provides primitives that map directly to Axe's concurrency model while remaining general enough to serve other potential front-ends in the future.

## Core Characteristics

BearVM uses a minimal, register-based intermediate representation with explicit basic blocks, phi nodes (in SSA form), and straightforward control flow. The IR includes support for concurrency operations: `spawn` to launch asynchronous function calls and `sync` to wait for and retrieve results.

These features allow Axe programs that use parallelism (recursive divide-and-conquer, task-based decomposition, producer-consumer patterns) to be expressed naturally and compiled efficiently.

## Execution Modes

### Interpreter

A small bytecode interpreter executes programs with low memory footprint and good portability. On simple loop microbenchmarks it has demonstrated performance competitive with or better than LuaJIT running in interpreter mode.

### JIT

An AArch64 JIT compiler is under development, targeting Apple Silicon. It generates native code using:

- Memory allocation with MAP_JIT on macOS  
- Correct write-protection handling via pthread_jit_write_protect_np  
- Instruction cache maintenance  
- ABI-compliant callee-saved register preservation  

The JIT aims to remove interpreter dispatch overhead from hot loops and parallel task bodies.

## Project Status

BearVM remains in early development. Concurrency runtime support (task scheduling, synchronization) is implemented at the IR level with ongoing work on efficient underlying execution.

No API or file format stability is guaranteed at this time.

## Relation to Axe

BearVM is not intended as a general-purpose language runtime. Its primary role is to serve as an efficient, concurrency-aware execution layer for the Axe compiler. Other front-ends may target BearVM in the future, but the design decisions (instruction selection, concurrency model, calling convention) are guided by Axe's requirements for expressing and executing highly parallel programs.

# License

Navid M (C) - GPL-3.0-only 
