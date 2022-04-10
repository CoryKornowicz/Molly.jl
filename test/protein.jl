@testset "Peptide" begin
    n_steps = 100
    temp = 298.0u"K"
    s = System(
        joinpath(data_dir, "5XER", "gmx_coords.gro"),
        joinpath(data_dir, "5XER", "gmx_top_ff.top");
        loggers=Dict(
            "temp"   => TemperatureLogger(10),
            "coords" => CoordinateLogger(10),
            "energy" => TotalEnergyLogger(10),
            "writer" => StructureWriter(10, temp_fp_pdb),
        ),
    )
    simulator = VelocityVerletIntegrator(
        dt=0.0002u"ps",
        coupling=AndersenThermostat(temp, 10.0u"ps"),
    )

    true_n_atoms = 5191
    @test length(s.atoms) == true_n_atoms
    @test length(s.coords) == true_n_atoms
    @test size(s.neighbor_finder.nb_matrix) == (true_n_atoms, true_n_atoms)
    @test size(s.neighbor_finder.matrix_14) == (true_n_atoms, true_n_atoms)
    @test length(s.pairwise_inters) == 2
    @test length(s.specific_inter_lists) == 3
    @test s.box_size == SVector(3.7146, 3.7146, 3.7146)u"nm"
    show(devnull, first(s.atoms))

    s.velocities = [velocity(a.mass, temp) .* 0.01 for a in s.atoms]
    @time simulate!(s, simulator, n_steps; parallel=false)

    traj = read(temp_fp_pdb, BioStructures.PDB)
    rm(temp_fp_pdb)
    @test BioStructures.countmodels(traj) == 11
    @test BioStructures.countatoms(first(traj)) == 5191
end

@testset "Peptide Float32" begin
    n_steps = 100
    temp = 298.0f0u"K"
    s = System(
        Float32,
        joinpath(data_dir, "5XER", "gmx_coords.gro"),
        joinpath(data_dir, "5XER", "gmx_top_ff.top");
        loggers=Dict(
            "temp"   => TemperatureLogger(typeof(1.0f0u"K"), 10),
            "coords" => CoordinateLogger(typeof(1.0f0u"nm"), 10),
            "energy" => TotalEnergyLogger(typeof(1.0f0u"kJ * mol^-1"), 10),
        ),
    )
    simulator = VelocityVerletIntegrator(
        dt=0.0002f0u"ps",
        coupling=AndersenThermostat(temp, 10.0f0u"ps"),
    )

    s.velocities = [velocity(a.mass, Float32(temp)) .* 0.01f0 for a in s.atoms]
    @time simulate!(s, simulator, n_steps; parallel=false)
end

@testset "OpenMM protein comparison" begin
    openmm_dir = joinpath(data_dir, "openmm_6mrr")
    ff = OpenMMForceField(joinpath.(ff_dir, ["ff99SBildn.xml", "tip3p_standard.xml", "his.xml"])...)
    show(devnull, ff)
    sys = System(joinpath(data_dir, "6mrr_equil.pdb"), ff; centre_coords=false)
    neighbors = find_neighbors(sys)

    for inter in ("bond", "angle", "proptor", "improptor", "lj", "coul", "all")
        if inter == "all"
            pin = sys.pairwise_inters
        elseif inter == "lj"
            pin = sys.pairwise_inters[1:1]
        elseif inter == "coul"
            pin = sys.pairwise_inters[2:2]
        else
            pin = ()
        end

        if inter == "all"
            sils = sys.specific_inter_lists
        elseif inter == "bond"
            sils = sys.specific_inter_lists[1:1]
        elseif inter == "angle"
            sils = sys.specific_inter_lists[2:2]
        elseif inter == "proptor"
            sils = sys.specific_inter_lists[3:3]
        elseif inter == "improptor"
            sils = sys.specific_inter_lists[4:4]
        else
            sils = ()
        end

        sys_part = System(
            atoms=sys.atoms,
            pairwise_inters=pin,
            specific_inter_lists=sils,
            coords=sys.coords,
            box_size=sys.box_size,
            neighbor_finder=sys.neighbor_finder,
        )

        forces_molly = forces(sys_part, neighbors; parallel=false)
        forces_openmm = SVector{3}.(eachrow(readdlm(joinpath(openmm_dir, "forces_$(inter)_only.txt"))))u"kJ * mol^-1 * nm^-1"
        # All force terms on all atoms must match at some threshold
        @test !any(d -> any(abs.(d) .> 1e-6u"kJ * mol^-1 * nm^-1"), forces_molly .- forces_openmm)

        E_molly = potential_energy(sys_part, neighbors)
        E_openmm = readdlm(joinpath(openmm_dir, "energy_$(inter)_only.txt"))[1] * u"kJ * mol^-1"
        # Energy must match at some threshold
        @test E_molly - E_openmm < 1e-5u"kJ * mol^-1"
    end

    # Run a short simulation with all interactions
    n_steps = 100
    simulator = VelocityVerletIntegrator(dt=0.0005u"ps")
    velocities_start = SVector{3}.(eachrow(readdlm(joinpath(openmm_dir, "velocities_300K.txt"))))u"nm * ps^-1"
    sys.velocities = deepcopy(velocities_start)
    @test kinetic_energy(sys) ≈ 65521.87288132431u"kJ * mol^-1"
    @test temperature(sys) ≈ 329.3202932884933u"K"

    simulate!(sys, simulator, n_steps; parallel=true)

    coords_openmm = SVector{3}.(eachrow(readdlm(joinpath(openmm_dir, "coordinates_$(n_steps)steps.txt"))))u"nm"
    vels_openmm   = SVector{3}.(eachrow(readdlm(joinpath(openmm_dir, "velocities_$(n_steps)steps.txt" ))))u"nm * ps^-1"

    coords_diff = sys.coords .- wrap_coords_vec.(coords_openmm, (sys.box_size,))
    vels_diff = sys.velocities .- vels_openmm
    # Coordinates and velocities at end must match at some threshold
    @test maximum(maximum(abs.(v)) for v in coords_diff) < 1e-9u"nm"
    @test maximum(maximum(abs.(v)) for v in vels_diff  ) < 1e-6u"nm * ps^-1"

    # Test with no units
    ff_nounits = OpenMMForceField(
        joinpath.(ff_dir, ["ff99SBildn.xml", "tip3p_standard.xml", "his.xml"])...;
        units=false,
    )
    sys_nounits = System(
        joinpath(data_dir, "6mrr_equil.pdb"),
        ff_nounits;
        velocities=deepcopy(ustrip_vec.(velocities_start)),
        units=false,
        centre_coords=false,
    )
    simulator_nounits = VelocityVerletIntegrator(dt=0.0005)
    @test kinetic_energy(sys_nounits)u"kJ * mol^-1" ≈ 65521.87288132431u"kJ * mol^-1"
    @test temperature(sys_nounits)u"K" ≈ 329.3202932884933u"K"

    E_openmm = readdlm(joinpath(openmm_dir, "energy_all_only.txt"))[1] * u"kJ * mol^-1"
    neighbors_nounits = find_neighbors(sys_nounits)
    @test isapprox(potential_energy(sys_nounits, neighbors_nounits) * u"kJ * mol^-1",
                    E_openmm; atol=1e-5u"kJ * mol^-1")

    simulate!(sys_nounits, simulator_nounits, n_steps; parallel=true)

    coords_diff = sys_nounits.coords * u"nm" .- wrap_coords_vec.(coords_openmm, (sys.box_size,))
    vels_diff = sys_nounits.velocities * u"nm * ps^-1" .- vels_openmm
    @test maximum(maximum(abs.(v)) for v in coords_diff) < 1e-9u"nm"
    @test maximum(maximum(abs.(v)) for v in vels_diff  ) < 1e-6u"nm * ps^-1"

    params_dic = extract_parameters(sys_nounits, ff_nounits)
    @test length(params_dic) == 639
    atoms_grad, pis_grad, sis_grad = inject_gradients(sys_nounits, params_dic)
    @test atoms_grad == sys_nounits.atoms
    @test pis_grad == sys_nounits.pairwise_inters

    # Test the same simulation on the GPU
    if run_gpu_tests
        sys = System(
            joinpath(data_dir, "6mrr_equil.pdb"),
            ff;
            velocities=cu(deepcopy(velocities_start)),
            gpu=true,
            centre_coords=false,
        )
        @test kinetic_energy(sys) ≈ 65521.87288132431u"kJ * mol^-1"
        @test temperature(sys) ≈ 329.3202932884933u"K"

        neighbors = find_neighbors(sys)
        @test isapprox(potential_energy(sys, neighbors), E_openmm; atol=1e-5u"kJ * mol^-1")

        simulate!(sys, simulator, n_steps)

        coords_diff = Array(sys.coords) .- wrap_coords_vec.(coords_openmm, (sys.box_size,))
        vels_diff = Array(sys.velocities) .- vels_openmm
        @test maximum(maximum(abs.(v)) for v in coords_diff) < 1e-9u"nm"
        @test maximum(maximum(abs.(v)) for v in vels_diff  ) < 1e-6u"nm * ps^-1"

        sys_nounits = System(
            joinpath(data_dir, "6mrr_equil.pdb"),
            ff_nounits;
            velocities=cu(deepcopy(ustrip_vec.(velocities_start))),
            units=false,
            gpu=true,
            centre_coords=false,
        )
        @test kinetic_energy(sys_nounits)u"kJ * mol^-1" ≈ 65521.87288132431u"kJ * mol^-1"
        @test temperature(sys_nounits)u"K" ≈ 329.3202932884933u"K"

        neighbors_nounits = find_neighbors(sys_nounits)
        @test isapprox(potential_energy(sys_nounits, neighbors_nounits) * u"kJ * mol^-1",
                        E_openmm; atol=1e-5u"kJ * mol^-1")

        simulate!(sys_nounits, simulator_nounits, n_steps)

        coords_diff = Array(sys_nounits.coords * u"nm") .- wrap_coords_vec.(coords_openmm, (sys.box_size,))
        vels_diff = Array(sys_nounits.velocities * u"nm * ps^-1") .- vels_openmm
        @test maximum(maximum(abs.(v)) for v in coords_diff) < 1e-9u"nm"
        @test maximum(maximum(abs.(v)) for v in vels_diff  ) < 1e-6u"nm * ps^-1"

        params_dic_gpu = extract_parameters(sys_nounits, ff_nounits)
        @test params_dic == params_dic_gpu
        atoms_grad, pis_grad, sis_grad = inject_gradients(sys_nounits, params_dic_gpu)
        @test atoms_grad == sys_nounits.atoms
        @test pis_grad == sys_nounits.pairwise_inters
    end
end

@testset "Implicit solvent" begin
    openmm_dir = joinpath(data_dir, "openmm_6mrr")
    ff = OpenMMForceField(joinpath.(ff_dir, ["ff99SBildn.xml", "his.xml"])...)

    for solvent_model in ("obc2", "gbn2")
        sys = System(
            joinpath(data_dir, "6mrr_nowater.pdb"),
            ff;
            box_size=SVector(100.0, 100.0, 100.0)u"nm",
            implicit_solvent=solvent_model,
            dist_cutoff=5.0u"nm",
            nl_dist=5.0u"nm",
            kappa=1.0u"nm^-1",
        )
        neighbors = find_neighbors(sys)

        forces_molly = forces(sys, neighbors)
        openmm_force_fp = joinpath(openmm_dir, "forces_$solvent_model.txt")
        forces_openmm = SVector{3}.(eachrow(readdlm(openmm_force_fp)))u"kJ * mol^-1 * nm^-1"
        @test !any(d -> any(abs.(d) .> 1e-3u"kJ * mol^-1 * nm^-1"), forces_molly .- forces_openmm)

        E_molly = potential_energy(sys, neighbors)
        openmm_E_fp = joinpath(openmm_dir, "energy_$solvent_model.txt")
        E_openmm = readdlm(openmm_E_fp)[1] * u"kJ * mol^-1"
        @test E_molly - E_openmm < 1e-2u"kJ * mol^-1"

        if solvent_model == "gbn2"
            sim = SteepestDescentMinimizer(tol=400.0u"kJ * mol^-1 * nm^-1")
            coords_start = deepcopy(sys.coords)
            simulate!(sys, sim)
            neighbors = find_neighbors(sys)
            @test potential_energy(sys, neighbors) < E_molly
            @test rmsd(coords_start, sys.coords) < 0.1u"nm"
        end
    end
end
