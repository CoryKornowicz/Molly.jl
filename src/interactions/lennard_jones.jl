export LennardJones, LennardJonesSoftCore

@doc raw"""
    LennardJones(; cutoff, nl_only, lorentz_mixing, weight_14, weight_solute_solvent,
                 force_units, energy_units, skip_shortcut)

The Lennard-Jones 6-12 interaction between two atoms.
The potential energy is defined as
```math
V(r_{ij}) = 4\varepsilon_{ij} \left[\left(\frac{\sigma_{ij}}{r_{ij}}\right)^{12} - \left(\frac{\sigma_{ij}}{r_{ij}}\right)^{6}\right]
```
and the force on each atom by
```math
\begin{aligned}
\vec{F}_i &= 24\varepsilon_{ij} \left(2\frac{\sigma_{ij}^{12}}{r_{ij}^{13}} - \frac{\sigma_{ij}^6}{r_{ij}^{7}}\right) \frac{\vec{r}_{ij}}{r_{ij}} \\
&= \frac{24\varepsilon_{ij}}{r_{ij}^2} \left[2\left(\frac{\sigma_{ij}^{6}}{r_{ij}^{6}}\right)^2 -\left(\frac{\sigma_{ij}}{r_{ij}}\right)^{6}\right] \vec{r}_{ij}
\end{aligned}
```
"""
struct LennardJones{S, C, W, WS, F, E} <: PairwiseInteraction
    cutoff::C
    nl_only::Bool
    lorentz_mixing::Bool
    weight_14::W
    weight_solute_solvent::WS
    force_units::F
    energy_units::E
end

function LennardJones(;
                        cutoff=NoCutoff(),
                        nl_only=false,
                        lorentz_mixing=true,
                        weight_14=1,
                        weight_solute_solvent=1,
                        force_units=u"kJ * mol^-1 * nm^-1",
                        energy_units=u"kJ * mol^-1",
                        skip_shortcut=false)
    return LennardJones{skip_shortcut, typeof(cutoff), typeof(weight_14), typeof(weight_solute_solvent),
                        typeof(force_units), typeof(energy_units)}(
        cutoff, nl_only, lorentz_mixing, weight_14, weight_solute_solvent, force_units, energy_units)
end

is_solute(at::Atom) = at.solute
is_solute(at) = false

function Base.zero(lj::LennardJones{S, C, W, WS, F, E}) where {S, C, W, WS, F, E}
    return LennardJones{S, C, W, WS, F, E}(
        lj.cutoff,
        false,
        false,
        zero(W),
        zero(WS),
        lj.force_units,
        lj.energy_units,
    )
end

function Base.:+(l1::LennardJones{S, C, W, WS, F, E},
                 l2::LennardJones{S, C, W, WS, F, E}) where {S, C, W, WS, F, E}
    return LennardJones{S, C, W, WS, F, E}(
        l1.cutoff,
        l1.nl_only,
        l1.lorentz_mixing,
        l1.weight_14 + l2.weight_14,
        l1.weight_solute_solvent + l2.weight_solute_solvent,
        l1.force_units,
        l1.energy_units,
    )
end

@inline @inbounds function force(inter::LennardJones{S, C},
                                    dr,
                                    coord_i,
                                    coord_j,
                                    atom_i,
                                    atom_j,
                                    boundary,
                                    weight_14::Bool=false) where {S, C}
    r2 = sum(abs2, dr)

    if !S && (iszero_value(atom_i.ϵ) || iszero_value(atom_j.ϵ) || iszero_value(atom_i.σ) || iszero_value(atom_j.σ))
        return ustrip.(zero(coord_i)) * inter.force_units
    end

    # Lorentz-Berthelot mixing rules use the arithmetic average for σ
    # Otherwise use the geometric average
    σ = inter.lorentz_mixing ? (atom_i.σ + atom_j.σ) / 2 : sqrt(atom_i.σ * atom_j.σ)
    if (is_solute(atom_i) && !is_solute(atom_j)) || (is_solute(atom_j) && !is_solute(atom_i))
        ϵ = inter.weight_solute_solvent * sqrt(atom_i.ϵ * atom_j.ϵ)
    else
        ϵ = sqrt(atom_i.ϵ * atom_j.ϵ)
    end

    cutoff = inter.cutoff
    σ2 = σ^2
    params = (σ2, ϵ)

    if cutoff_points(C) == 0
        f = force_divr_nocutoff(inter, r2, inv(r2), params)
    elseif cutoff_points(C) == 1
        r2 > cutoff.sqdist_cutoff && return ustrip.(zero(coord_i)) * inter.force_units

        f = force_divr_cutoff(cutoff, r2, inter, params)
    elseif cutoff_points(C) == 2
        r2 > cutoff.sqdist_cutoff && return ustrip.(zero(coord_i)) * inter.force_units

        if r2 < cutoff.sqdist_activation
            f = force_divr_nocutoff(inter, r2, inv(r2), params)
        else
            f = force_divr_cutoff(cutoff, r2, inter, params)
        end
    end

    if weight_14
        return f * dr * inter.weight_14
    else
        return f * dr
    end
end

function force_divr_nocutoff(::LennardJones, r2, invr2, (σ2, ϵ))
    six_term = (σ2 * invr2) ^ 3

    return (24ϵ * invr2) * (2 * six_term ^ 2 - six_term)
end

@inline @inbounds function potential_energy(inter::LennardJones{S, C},
                                            dr,
                                            coord_i,
                                            coord_j,
                                            atom_i,
                                            atom_j,
                                            boundary,
                                            weight_14::Bool=false) where {S, C}
    r2 = sum(abs2, dr)

    if !S && (iszero_value(atom_i.ϵ) || iszero_value(atom_j.ϵ) || iszero_value(atom_i.σ) || iszero_value(atom_j.σ))
        return ustrip(zero(coord_i[1])) * inter.energy_units
    end

    σ = inter.lorentz_mixing ? (atom_i.σ + atom_j.σ) / 2 : sqrt(atom_i.σ * atom_j.σ)
    if (is_solute(atom_i) && !is_solute(atom_j)) || (is_solute(atom_j) && !is_solute(atom_i))
        ϵ = inter.weight_solute_solvent * sqrt(atom_i.ϵ * atom_j.ϵ)
    else
        ϵ = sqrt(atom_i.ϵ * atom_j.ϵ)
    end

    cutoff = inter.cutoff
    σ2 = σ^2
    params = (σ2, ϵ)

    if cutoff_points(C) == 0
        pe = potential(inter, r2, inv(r2), params)
    elseif cutoff_points(C) == 1
        r2 > cutoff.sqdist_cutoff && return ustrip(zero(coord_i[1])) * inter.energy_units

        pe = potential_cutoff(cutoff, r2, inter, params)
    elseif cutoff_points(C) == 2
        r2 > cutoff.sqdist_cutoff && return ustrip(zero(coord_i[1])) * inter.energy_units

        if r2 < cutoff.sqdist_activation
            pe = potential(inter, r2, inv(r2), params)
        else
            pe = potential_cutoff(cutoff, r2, inter, params)
        end
    end

    if weight_14
        return pe * inter.weight_14
    else
        return pe
    end
end

function potential(::LennardJones, r2, invr2, (σ2, ϵ))
    six_term = (σ2 * invr2) ^ 3

    return 4ϵ * (six_term ^ 2 - six_term)
end

@doc raw"""
    LennardJonesSoftCore(; cutoff, α, λ, p, nl_only, lorentz_mixing, weight_14, weight_solute_solvent,
                 force_units, energy_units, skip_shortcut)

The Lennard-Jones 6-12 interaction between two atoms with a soft core.
The potential energy is defined as
```math
V(r_{ij}) = 4\varepsilon_{ij} \left[\left(\frac{\sigma_{ij}}{r_{ij}^{\text{sc}}}\right)^{12} - \left(\frac{\sigma_{ij}}{r_{ij}^{\text{sc}}}\right)^{6}\right]
```
and the force on each atom by
```math
\begin{aligned}
\vec{F}_i &= 24\varepsilon_{ij} \left(2\frac{\sigma_{ij}^{12}}{(r_{ij}^{\text{sc}})^{13}} - \frac{\sigma_{ij}^6}{(r_{ij}^{\text{sc}})^{7}}\right) \left(\frac{r_{ij}}{r_{ij}^{\text{sc}}}\right)^5 \frac{\vec{r}_{ij}}{r_{ij}}
\end{aligned}
```

where ``r_{ij}^{\text{sc}} = \left(r_{ij}^6 + \alpha \sigma_{ij}^6 \lambda^p \right)^{1/6}``. Here, ``\alpha``,
``\lambda``, and ``p`` adjust the functional form of the soft core of the potential. For `α=0` or `λ=0`
we get the standard Lennard-Jones potential.
"""
struct LennardJonesSoftCore{S, C, A, L, P, R, W, WS, F, E} <: PairwiseInteraction
    cutoff::C
    α::A
    λ::L
    p::P
    σ6_fac::R
    nl_only::Bool
    lorentz_mixing::Bool
    weight_14::W
    weight_solute_solvent::WS
    force_units::F
    energy_units::E
end

function LennardJonesSoftCore(;
                        cutoff=NoCutoff(),
                        α=1,
                        λ=0,
                        p=2,
                        nl_only=false,
                        lorentz_mixing=true,
                        weight_14=1,
                        weight_solute_solvent=1,
                        force_units=u"kJ * mol^-1 * nm^-1",
                        energy_units=u"kJ * mol^-1",
                        skip_shortcut=false)
    σ6_fac = α*λ^p
    return LennardJonesSoftCore{skip_shortcut, typeof(cutoff), typeof(α), typeof(λ), typeof(p), typeof(σ6_fac),
                        typeof(weight_14), typeof(weight_solute_solvent), typeof(force_units), typeof(energy_units)}(
        cutoff, α, λ, p, σ6_fac, nl_only, lorentz_mixing, weight_14, weight_solute_solvent,
        force_units, energy_units)
end

@inline @inbounds function force(inter::LennardJonesSoftCore{S, C},
                                    dr,
                                    coord_i,
                                    coord_j,
                                    atom_i,
                                    atom_j,
                                    boundary,
                                    weight_14::Bool=false) where {S, C}
    r2 = sum(abs2, dr)

    if !S && (iszero_value(atom_i.ϵ) || iszero_value(atom_j.ϵ) || iszero_value(atom_i.σ) || iszero_value(atom_j.σ))
        return ustrip.(zero(coord_i)) * inter.force_units
    end

    # Lorentz-Berthelot mixing rules use the arithmetic average for σ
    # Otherwise use the geometric average
    σ = inter.lorentz_mixing ? (atom_i.σ + atom_j.σ) / 2 : sqrt(atom_i.σ * atom_j.σ)
    if (is_solute(atom_i) && !is_solute(atom_j)) || (is_solute(atom_j) && !is_solute(atom_i))
        ϵ = inter.weight_solute_solvent * sqrt(atom_i.ϵ * atom_j.ϵ)
    else
        ϵ = sqrt(atom_i.ϵ * atom_j.ϵ)
    end

    cutoff = inter.cutoff
    σ2 = σ^2
    params = (σ2, ϵ, inter.σ6_fac)

    if cutoff_points(C) == 0
        f = force_divr_nocutoff(inter, r2, inv(r2), params)
    elseif cutoff_points(C) == 1
        r2 > cutoff.sqdist_cutoff && return ustrip.(zero(coord_i)) * inter.force_units

        f = force_divr_cutoff(cutoff, r2, inter, params)
    elseif cutoff_points(C) == 2
        r2 > cutoff.sqdist_cutoff && return ustrip.(zero(coord_i)) * inter.force_units

        if r2 < cutoff.sqdist_activation
            f = force_divr_nocutoff(inter, r2, inv(r2), params)
        else
            f = force_divr_cutoff(cutoff, r2, inter, params)
        end
    end

    if weight_14
        return f * dr * inter.weight_14
    else
        return f * dr
    end
end

function force_divr_nocutoff(::LennardJonesSoftCore, r2, invr2, (σ2, ϵ, σ6_fac))
    inv_rsc6 = inv(r2^3 + σ2^3 * σ6_fac)  # rsc = (r2^3 + α * σ2^3 * λ^p)^(1/6)
    inv_rsc  = √cbrt(inv_rsc6)
    six_term = σ2^3 * inv_rsc6

    ff  = (24ϵ * inv_rsc)
    ff *= (2 * six_term^2 - six_term)
    ff *= √r2^5 * inv_rsc^5
    # √invr2 is for normalizing dr
    return   ff * √invr2
end

@inline @inbounds function potential_energy(inter::LennardJonesSoftCore{S, C},
                                            dr,
                                            coord_i,
                                            coord_j,
                                            atom_i,
                                            atom_j,
                                            boundary,
                                            weight_14::Bool=false) where {S, C}
    r2 = sum(abs2, dr)

    if !S && (iszero_value(atom_i.ϵ) || iszero_value(atom_j.ϵ) || iszero_value(atom_i.σ) || iszero_value(atom_j.σ))
        return ustrip(zero(coord_i[1])) * inter.energy_units
    end

    σ = inter.lorentz_mixing ? (atom_i.σ + atom_j.σ) / 2 : sqrt(atom_i.σ * atom_j.σ)
    if (is_solute(atom_i) && !is_solute(atom_j)) || (is_solute(atom_j) && !is_solute(atom_i))
        ϵ = inter.weight_solute_solvent * sqrt(atom_i.ϵ * atom_j.ϵ)
    else
        ϵ = sqrt(atom_i.ϵ * atom_j.ϵ)
    end

    cutoff = inter.cutoff
    σ2 = σ^2
    params = (σ2, ϵ, inter.σ6_fac)

    if cutoff_points(C) == 0
        pe = potential(inter, r2, inv(r2), params)
    elseif cutoff_points(C) == 1
        r2 > cutoff.sqdist_cutoff && return ustrip(zero(coord_i[1])) * inter.energy_units

        pe = potential_cutoff(cutoff, r2, inter, params)
    elseif cutoff_points(C) == 2
        r2 > cutoff.sqdist_cutoff && return ustrip(zero(coord_i[1])) * inter.energy_units

        if r2 < cutoff.sqdist_activation
            pe = potential(inter, r2, inv(r2), params)
        else
            pe = potential_cutoff(cutoff, r2, inter, params)
        end
    end

    if weight_14
        return pe * inter.weight_14
    else
        return pe
    end
end

function potential(::LennardJonesSoftCore, r2, invr2, (σ2, ϵ, σ6_fac))
    six_term = σ2^3 * inv(r2^3 + σ2^3 * σ6_fac)

    return 4ϵ * (six_term ^ 2 - six_term)
end
