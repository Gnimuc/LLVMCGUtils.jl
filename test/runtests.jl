using LLVMCGUtils
using Test
using LLVM, InteractiveUtils
using LLVMCGUtils: emit_pointer_from_objref, decay_derived, collect_global_ctors

@generated function pointer_from_objref_reimpl(x)
    Context() do ctx
        T_prjlvalue = convert(LLVMType, Any; ctx, allow_boxed = true)
        rettype = convert(LLVMType, Ptr{Cvoid}; ctx)
        fn, _ = LLVM.Interop.create_function(rettype, [T_prjlvalue])
        param = only(parameters(fn))
        mod = LLVM.parent(fn)
        Builder(ctx) do builder
            entry = BasicBlock(fn, "entry"; ctx)
            position!(builder, entry)

            callinst = emit_pointer_from_objref(mod, builder, decay_derived(builder, param))

            ret!(builder, ptrtoint!(builder, callinst, rettype))
        end
        LLVM.Interop.call_function(fn, Ptr{Cvoid}, Tuple{Any}, :x)
    end
end

@testset "pointer_from_objref" begin
    x = Ref{Int}(1)
    @test pointer_from_objref_reimpl(x) == pointer_from_objref(x)
    @test pointer_from_objref_reimpl(x) == Base.unsafe_convert(Ptr{Cvoid}, x)
    @info "Printing verbose IR code:"
    @code_llvm raw=true optimize=true pointer_from_objref_reimpl(x)
    @code_llvm raw=true optimize=true pointer_from_objref(x)
end

@generated run_global_ctors(mod) = LLVM.Interop.call_function(collect_global_ctors(mod), Cvoid)

# from LLJITDumpObjects.cpp
IR = raw"""
@InitializersRunFlag = external global i32
@DeinitializersRunFlag = external global i32

declare i32 @__cxa_atexit(void (i8*)*, i8*, i8*)
@__dso_handle = external hidden global i8

@llvm.global_ctors =
appending global [1 x { i32, void ()*, i8* }]
    [{ i32, void ()*, i8* } { i32 65535, void ()* @init_func, i8* null }]

define internal void @init_func() {
entry:
store i32 1, i32* @InitializersRunFlag
%0 = call i32 @__cxa_atexit(void (i8*)* @deinit_func, i8* null,
                            i8* @__dso_handle)
ret void
}

define internal void @deinit_func(i8* %0) {
store i32 1, i32* @DeinitializersRunFlag
ret void
}
"""

@testset "collect_global_ctors" begin
    Context() do ctx
        m = parse(LLVM.Module, IR)
        @test_nothrow run_global_ctors(m)
    end
end
