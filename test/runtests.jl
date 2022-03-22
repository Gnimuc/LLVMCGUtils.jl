using LLVMCGUtils
using Test
using LLVM, InteractiveUtils
using LLVMCGUtils: emit_pointer_from_objref, decay_derived

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
    @code_llvm raw=true pointer_from_objref_reimpl(x)
    @code_llvm raw=true pointer_from_objref(x)
end
