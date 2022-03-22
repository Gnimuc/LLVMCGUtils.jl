module LLVMCGUtils

using LLVM

# AddressSpace
const GENERIC = 0
const TRACKED = 10
const DERIVED = 11
const CALLEEROOTED = 12
const LOADED = 13

# jlvalue types
@inline get_jlvalue_ty(ctx::Context) = LLVM.StructType(LLVMType[]; ctx)
@inline get_pjlvalue_ty(ctx::Context) = LLVM.PointerType(get_jlvalue_ty(ctx), GENERIC)
@inline get_prjlvalue_ty(ctx::Context) = LLVM.PointerType(get_jlvalue_ty(ctx), TRACKED)
@inline get_ppjlvalue_ty(ctx::Context) = LLVM.PointerType(get_pjlvalue_ty(ctx), GENERIC)
@inline get_pprjlvalue_ty(ctx::Context) = LLVM.PointerType(get_prjlvalue_ty(ctx), GENERIC)

@inline function get_jlfunc_ty(ctx::Context)
    T_prjlvalue = get_prjlvalue_ty(ctx)  # function
    T_pprjlvalue = LLVM.PointerType(T_prjlvalue, GENERIC) # args[]
    T_nargs = LLVM.Int32Type(ctx) # nargs
    return LLVM.FunctionType(T_prjlvalue, [T_prjlvalue, T_pprjlvalue, T_nargs])
end

@inline function get_jlfuncparams_ty(ctx::Context)
    T_prjlvalue = get_prjlvalue_ty(ctx)  # function
    T_pprjlvalue = LLVM.PointerType(T_prjlvalue, GENERIC) # args[]
    T_nargs = LLVM.Int32Type(ctx) # nargs
    T_sparam_vals = T_pprjlvalue # linfo->sparam_vals
    return LLVM.FunctionType(T_prjlvalue, [T_prjlvalue, T_pprjlvalue, T_nargs, T_sparam_vals])
end

@inline get_voidfunc_ty(ctx::Context) = LLVM.FunctionType(LLVM.VoidType(ctx))
@inline get_pvoidfunc_ty(ctx::Context) = LLVM.PointerType(get_voidfunc_ty(ctx), GENERIC)

# important functions
# TODO...

# placeholder functions
function create_gcroot_flush(mod::LLVM.Module)
    ctx = context(mod)
    ft = LLVM.FunctionType(get_voidfunc_ty(ctx))
    fn = LLVM.Function(mod, "julia.gcroot_flush", ft)
    return fn
end

function create_gc_preserve_begin(mod::LLVM.Module)
    ctx = context(mod)
    ft = LLVM.FunctionType(LLVM.TokenType(ctx); vararg=true)
    fn = LLVM.Function(mod, "llvm.julia.gc_preserve_begin", ft)
    return fn
end

function create_gc_preserve_end(mod::LLVM.Module)
    ctx = context(mod)
    ft = LLVM.FunctionType(get_voidfunc_ty(ctx), [LLVM.TokenType(ctx)]; vararg=true)
    fn = LLVM.Function(mod, "llvm.julia.gc_preserve_end", ft)
    return fn
end

function create_except_enter(mod::LLVM.Module)
    ctx = context(mod)
    ft = LLVM.FunctionType(LLVM.Int32Type(ctx); vararg=true)
    fn = LLVM.Function(mod, "julia.except_enter", ft)
    fn_attrs = function_attributes(fn)
    push!(fn_attrs, StringAttribute("returns_twice", ""; ctx))
    return fn
end

function create_pointer_from_objref(mod::LLVM.Module)
    ctx = context(mod)
    ft = LLVM.FunctionType(get_pjlvalue_ty(ctx), [LLVM.PointerType(get_jlvalue_ty(ctx), DERIVED)])
    fn = LLVM.Function(mod, "julia.pointer_from_objref", ft)
    fn_attrs = function_attributes(fn)
    push!(fn_attrs, StringAttribute("readnone", ""; ctx))
    push!(fn_attrs, StringAttribute("nounwind", ""; ctx))
    ret_attrs = return_attributes(fn)
    push!(ret_attrs, StringAttribute("nonnull", ""; ctx))
    return fn
end

# utils
function track_pjlvalue(builder::Builder, v::Value)
    ctx = context(v)
    T_jlvalue = get_jlvalue_ty(ctx)
    T_pjlvalue = LLVM.PointerType(T_jlvalue, GENERIC)
    @assert llvmtype(v) == T_pjlvalue
    T_prjlvalue = LLVM.PointerType(T_jlvalue, TRACKED)
    return addrspacecast!(builder, v, T_prjlvalue)
end

function maybe_decay_untracked(builder::Builder, v::Value)
    ctx = context(v)
    T_jlvalue = get_jlvalue_ty(ctx)
    T_pjlvalue = LLVM.PointerType(T_jlvalue, GENERIC)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, TRACKED)
    if llvmtype(v) == T_pjlvalue
        return addrspacecast!(builder, v, T_prjlvalue)
    end
    @assert llvmtype(v) == T_prjlvalue
    return v
end

function decay_derived(builder::Builder, v::Value)
    ty = llvmtype(v)
    addrspace(ty) == DERIVED && return v
    new_ty = LLVM.PointerType(eltype(ty), DERIVED) # TODO:[#44310][LLVM 13] use getWithSamePointeeType instead
    return addrspacecast!(builder, v, new_ty)
end

function maybe_decay_tracked(builder::Builder, v::Value)
    ty = llvmtype(v)
    addrspace(ty) != TRACKED && return v
    new_ty = LLVM.PointerType(eltype(ty), DERIVED) # TODO:[#44310][LLVM 13] use getWithSamePointeeType instead
    return addrspacecast!(builder, v, new_ty)
end

function mark_callee_rooted(builder::Builder, v::Value)
    ctx = context(v)
    T_jlvalue = get_jlvalue_ty(ctx)
    T_pjlvalue = LLVM.PointerType(T_jlvalue, GENERIC)
    T_prjlvalue = LLVM.PointerType(T_jlvalue, TRACKED)
    ty = llvmtype(v)
    @assert ty == T_pjlvalue || ty == T_prjlvalue
    T_callee_rooted = LLVM.PointerType(T_jlvalue, CALLEEROOTED)
    return addrspacecast!(builder, v, T_callee_rooted)
end

function emit_pointer_from_objref(mod::LLVM.Module, builder::Builder, v::Value)
    address_space = addrspace(llvmtype(v))
    if address_space != TRACKED && address_space != DERIVED
        return v
    end
    v = decay_derived(builder, v)
    ctx = context(v)
    T_jlvalue = get_jlvalue_ty(ctx)
    ty = LLVM.PointerType(T_jlvalue, DERIVED)
    if llvmtype(v) != ty
        v = bitcast!(builder, v, ty)
    end
    funcs = functions(mod)
    if haskey(funcs, "julia.pointer_from_objref")
        fn = funcs["julia.pointer_from_objref"]
    else
        fn = create_pointer_from_objref(mod)
    end
    callinst = call!(builder, fn, [v])
    # TODO: sync attributes
    return callinst
end

function emit_bitcast(builder::Builder, v::Value, jl_value::Type)
    v_as = addrspace(llvmtype(v))
    if jl_value isa LLVM.PointerType && v_as != addrspace(jl_value)
        jl_value_addr = LLVM.PointerType(jl_value, v_as) # TODO:[#44310][LLVM 13] use getWithSamePointeeType instead
        return bitcast!(builder, v, jl_value_addr)
    else
        return bitcast!(builder, v, jl_value)
    end
end

maybe_bitcast(builder::Builder, v::Value, to::Type) = to != llvmtype(v) ? emit_bitcast(builder, v, to) : v

end
