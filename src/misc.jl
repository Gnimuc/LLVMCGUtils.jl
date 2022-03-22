function collect_global_ctors(mod::LLVM.Module)
    gvs = LLVM.globals(mod)
    haskey(gvs, "llvm.global_ctors") || return nothing
    gv = gvs["llvm.global_ctors"]
    list = LLVM.initializer(gv)
    ctx = LLVM.context(mod)
    llvm_void = convert(LLVMType, Cvoid; ctx)
    f = LLVM.Function(mod, "jl_gctors", LLVM.FunctionType(llvm_void))
    LLVM.Builder(ctx) do builder
        entry = LLVM.BasicBlock(f, "entry"; ctx)
        LLVM.position!(builder, entry)
        if !isnothing(list)
            arr = only(operands(gv))
            @assert arr isa LLVM.ConstantArray
            for op in operands(arr)
                op isa LLVM.ConstantStruct || continue
                fi = operands(op)[2]
                @assert fi isa LLVM.Function
                # TODO: handle constant expression casts
                call!(builder, fi)
            end
        end
        ret!(builder)
    end
    unsafe_delete!(mod, gv)
    return f
end
