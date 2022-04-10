@testset "Lennard-Jones 2D" begin
    n_atoms = 10
    n_steps = 20_000
    temp = 298.0u"K"
    box_size = SVector(2.0, 2.0)u"nm"
    simulator = VelocityVerlet(dt=0.002u"ps", coupling=AndersenThermostat(temp, 10.0u"ps"))

    s = System(
        atoms=[Atom(charge=0.0, mass=10.0u"u", σ=0.3u"nm", ϵ=0.2u"kJ * mol^-1") for i in 1:n_atoms],
        pairwise_inters=(LennardJones(nl_only=true),),
        coords=place_atoms(n_atoms, box_size, 0.3u"nm"),
        velocities=[velocity(10.0u"u", temp; dims=2) .* 0.01 for i in 1:n_atoms],
        box_size=box_size,
        neighbor_finder=DistanceNeighborFinder(nb_matrix=trues(n_atoms, n_atoms), n_steps=10, dist_cutoff=2.0u"nm"),
        loggers=Dict("temp" => TemperatureLogger(100),
                     "coords" => CoordinateLogger(100; dims=2)),
    )

    show(devnull, s)

    @time simulate!(s, simulator, n_steps; parallel=false)

    @test length(s.loggers["coords"].coords) == 201
    final_coords = last(s.loggers["coords"].coords)
    @test all(all(c .> 0.0u"nm") for c in final_coords)
    @test all(all(c .< box_size) for c in final_coords)
    displacements(final_coords, box_size)
    distances(final_coords, box_size)
    rdf(final_coords, box_size)

    run_visualize_tests && visualize(s.loggers["coords"], box_size, temp_fp_viz)
end

@testset "Lennard-Jones" begin
    n_atoms = 100
    n_steps = 20_000
    temp = 298.0u"K"
    box_size = SVector(2.0, 2.0, 2.0)u"nm"
    simulator = VelocityVerlet(dt=0.002u"ps", coupling=AndersenThermostat(temp, 10.0u"ps"))
    parallel_list = run_parallel_tests ? (false, true) : (false,)

    for parallel in parallel_list
        s = System(
            atoms=[Atom(charge=0.0, mass=10.0u"u", σ=0.3u"nm", ϵ=0.2u"kJ * mol^-1") for i in 1:n_atoms],
            atoms_data=[AtomData(atom_name="AR", res_number=i, res_name="AR") for i in 1:n_atoms],
            pairwise_inters=(LennardJones(nl_only=true),),
            coords=place_atoms(n_atoms, box_size, 0.3u"nm"),
            velocities=[velocity(10.0u"u", temp) .* 0.01 for i in 1:n_atoms],
            box_size=box_size,
            neighbor_finder=DistanceNeighborFinder(nb_matrix=trues(n_atoms, n_atoms), n_steps=10, dist_cutoff=2.0u"nm"),
            loggers=Dict("temp"   => TemperatureLogger(100),
                         "coords" => CoordinateLogger(100),
                         "vels"   => VelocityLogger(100),
                         "energy" => TotalEnergyLogger(100),
                         "ke"     => KineticEnergyLogger(100),
                         "pe"     => PotentialEnergyLogger(100),
                         "writer" => StructureWriter(100, temp_fp_pdb)),
        )

        nf_tree = TreeNeighborFinder(nb_matrix=trues(n_atoms, n_atoms), n_steps=10, dist_cutoff=2.0u"nm")
        neighbors = find_neighbors(s, s.neighbor_finder; parallel=parallel)
        neighbors_tree = find_neighbors(s, nf_tree; parallel=parallel)
        @test neighbors.list == neighbors_tree.list

        @time simulate!(s, simulator, n_steps; parallel=parallel)

        final_coords = last(s.loggers["coords"].coords)
        @test all(all(c .> 0.0u"nm") for c in final_coords)
        @test all(all(c .< box_size) for c in final_coords)
        displacements(final_coords, box_size)
        distances(final_coords, box_size)
        rdf(final_coords, box_size)

        traj = read(temp_fp_pdb, BioStructures.PDB)
        rm(temp_fp_pdb)
        @test BioStructures.countmodels(traj) == 201
        @test BioStructures.countatoms(first(traj)) == 100

        run_visualize_tests && visualize(s.loggers["coords"], box_size, temp_fp_viz)
    end
end

@testset "Lennard-Jones simulators" begin
    n_atoms = 100
    n_steps = 20_000
    temp = 298.0u"K"
    box_size = SVector(2.0, 2.0, 2.0)u"nm"
    coords = place_atoms(n_atoms, box_size, 0.3u"nm")
    simulators = [
        Verlet(dt=0.002u"ps", coupling=AndersenThermostat(temp, 10.0u"ps")),
        StormerVerlet(dt=0.002u"ps"),
        LangevinIntegrator(dt=0.002u"ps", temperature=temp, friction=1.0u"ps^-1"),
    ]

    s = System(
        atoms=[Atom(charge=0.0, mass=10.0u"u", σ=0.3u"nm", ϵ=0.2u"kJ * mol^-1") for i in 1:n_atoms],
        pairwise_inters=(LennardJones(nl_only=true),),
        coords=coords,
        box_size=box_size,
        neighbor_finder=DistanceNeighborFinder(nb_matrix=trues(n_atoms, n_atoms), n_steps=10, dist_cutoff=2.0u"nm"),
        loggers=Dict("coords" => CoordinateLogger(100)),
    )
    random_velocities!(s, temp)

    for simulator in simulators
        @time simulate!(s, simulator, n_steps; parallel=false)
    end
end

@testset "Diatomic molecules" begin
    n_atoms = 100
    n_steps = 20_000
    temp = 298.0u"K"
    box_size = SVector(2.0, 2.0, 2.0)u"nm"
    coords = place_atoms(n_atoms ÷ 2, box_size, 0.3u"nm")
    for i in 1:length(coords)
        push!(coords, coords[i] .+ [0.1, 0.0, 0.0]u"nm")
    end
    bonds = InteractionList2Atoms(
        collect(1:(n_atoms ÷ 2)),
        collect((1 + n_atoms ÷ 2):n_atoms),
        repeat([""], n_atoms ÷ 2),
        [HarmonicBond(b0=0.1u"nm", kb=300_000.0u"kJ * mol^-1 * nm^-2") for i in 1:(n_atoms ÷ 2)],
    )
    nb_matrix = trues(n_atoms, n_atoms)
    for i in 1:(n_atoms ÷ 2)
        nb_matrix[i, i + (n_atoms ÷ 2)] = false
        nb_matrix[i + (n_atoms ÷ 2), i] = false
    end
    simulator = VelocityVerlet(dt=0.002u"ps", coupling=AndersenThermostat(temp, 10.0u"ps"))

    s = System(
        atoms=[Atom(charge=0.0, mass=10.0u"u", σ=0.3u"nm", ϵ=0.2u"kJ * mol^-1") for i in 1:n_atoms],
        pairwise_inters=(LennardJones(nl_only=true),),
        specific_inter_lists=(bonds,),
        coords=coords,
        velocities=[velocity(10.0u"u", temp) .* 0.01 for i in 1:n_atoms],
        box_size=box_size,
        neighbor_finder=DistanceNeighborFinder(nb_matrix=trues(n_atoms, n_atoms), n_steps=10, dist_cutoff=2.0u"nm"),
        loggers=Dict("temp" => TemperatureLogger(10),
                        "coords" => CoordinateLogger(10)),
    )

    @time simulate!(s, simulator, n_steps; parallel=false)

    if run_visualize_tests
        visualize(s.loggers["coords"], box_size, temp_fp_viz;
                    connections=[(i, i + (n_atoms ÷ 2)) for i in 1:(n_atoms ÷ 2)],
                    trails=2)
    end
end

@testset "Pairwise interactions" begin
    n_atoms = 100
    n_steps = 20_000
    temp = 298.0u"K"
    box_size = SVector(2.0, 2.0, 2.0)u"nm"
    G = 10.0u"kJ * nm * u^-2 * mol^-1"
    simulator = VelocityVerlet(dt=0.002u"ps", coupling=AndersenThermostat(temp, 10.0u"ps"))
    pairwise_inter_types = (
        LennardJones(nl_only=true), LennardJones(nl_only=false),
        LennardJones(cutoff=DistanceCutoff(1.0u"nm"), nl_only=true),
        LennardJones(cutoff=ShiftedPotentialCutoff(1.0u"nm"), nl_only=true),
        LennardJones(cutoff=ShiftedForceCutoff(1.0u"nm"), nl_only=true),
        LennardJones(cutoff=CubicSplineCutoff(0.6u"nm", 1.0u"nm"), nl_only=true),
        SoftSphere(nl_only=true), SoftSphere(nl_only=false),
        Mie(m=5, n=10, nl_only=true), Mie(m=5, n=10, nl_only=false),
        Coulomb(nl_only=true), Coulomb(nl_only=false),
        CoulombReactionField(dist_cutoff=1.0u"nm", nl_only=true),
        CoulombReactionField(dist_cutoff=1.0u"nm", nl_only=false),
        Gravity(G=G, nl_only=true), Gravity(G=G, nl_only=false),
    )

    @testset "$inter" for inter in pairwise_inter_types
        if inter.nl_only
            neighbor_finder = DistanceNeighborFinder(nb_matrix=trues(n_atoms, n_atoms), n_steps=10,
                                                        dist_cutoff=1.5u"nm")
        else
            neighbor_finder = NoNeighborFinder()
        end

        s = System(
            atoms=[Atom(charge=i % 2 == 0 ? -1.0 : 1.0, mass=10.0u"u", σ=0.2u"nm",
                        ϵ=0.2u"kJ * mol^-1") for i in 1:n_atoms],
            pairwise_inters=(inter,),
            coords=place_atoms(n_atoms, box_size, 0.2u"nm"),
            velocities=[velocity(10.0u"u", temp) .* 0.01 for i in 1:n_atoms],
            box_size=box_size,
            neighbor_finder=neighbor_finder,
            loggers=Dict("temp" => TemperatureLogger(100),
                         "coords" => CoordinateLogger(100),
                         "energy" => TotalEnergyLogger(100)),
        )

        @time simulate!(s, simulator, n_steps)
    end
end

@testset "Units" begin
    n_atoms = 100
    n_steps = 2_000 # Does diverge for longer simulations or higher velocities
    temp = 298.0u"K"
    box_size = SVector(2.0, 2.0, 2.0)u"nm"
    coords = place_atoms(n_atoms, box_size, 0.3u"nm")
    velocities = [velocity(10.0u"u", temp) .* 0.01 for i in 1:n_atoms]
    simulator = VelocityVerlet(dt=0.002u"ps")
    simulator_nounits = VelocityVerlet(dt=0.002)

    s = System(
        atoms=[Atom(charge=0.0, mass=10.0u"u", σ=0.3u"nm", ϵ=0.2u"kJ * mol^-1") for i in 1:n_atoms],
        pairwise_inters=(LennardJones(nl_only=true),),
        coords=coords,
        velocities=velocities,
        box_size=box_size,
        neighbor_finder=DistanceNeighborFinder(nb_matrix=trues(n_atoms, n_atoms), n_steps=10, dist_cutoff=2.0u"nm"),
        loggers=Dict("temp" => TemperatureLogger(100),
                     "coords" => CoordinateLogger(100),
                     "energy" => TotalEnergyLogger(100)),
    )

    s_nounits = System(
        atoms=[Atom(charge=0.0, mass=10.0, σ=0.3, ϵ=0.2) for i in 1:n_atoms],
        pairwise_inters=(LennardJones(nl_only=true),),
        coords=ustrip_vec.(coords),
        velocities=ustrip_vec.(velocities),
        box_size=ustrip.(box_size),
        neighbor_finder=DistanceNeighborFinder(nb_matrix=trues(n_atoms, n_atoms), n_steps=10, dist_cutoff=2.0),
        loggers=Dict("temp" => TemperatureLogger(Float64, 100),
                     "coords" => CoordinateLogger(Float64, 100),
                     "energy" => TotalEnergyLogger(Float64, 100)),
        force_units=NoUnits,
        energy_units=NoUnits,
    )

    neighbors = find_neighbors(s, s.neighbor_finder; parallel=false)
    neighbors_nounits = find_neighbors(s_nounits, s_nounits.neighbor_finder; parallel=false)
    accel_diff = accelerations(s, neighbors) .- accelerations(s_nounits, neighbors_nounits)u"kJ * mol^-1 * nm^-1 * u^-1"
    @test iszero(accel_diff)

    simulate!(s, simulator, n_steps; parallel=false)
    simulate!(s_nounits, simulator_nounits, n_steps; parallel=false)

    coords_diff = s.loggers["coords"].coords[end] .- s_nounits.loggers["coords"].coords[end] * u"nm"
    @test median([maximum(abs.(c)) for c in coords_diff]) < 1e-8u"nm"

    final_energy = s.loggers["energy"].energies[end]
    final_energy_nounits = s_nounits.loggers["energy"].energies[end] * u"kJ * mol^-1"
    @test isapprox(final_energy, final_energy_nounits, atol=5e-4u"kJ * mol^-1")
end

@testset "Different implementations" begin
    n_atoms = 400
    atom_mass = 10.0u"u"
    box_size = SVector(6.0, 6.0, 6.0)u"nm"
    temp = 1.0u"K"
    starting_coords = place_diatomics(n_atoms ÷ 2, box_size, 0.2u"nm", 0.2u"nm")
    starting_velocities = [velocity(atom_mass, temp) for i in 1:n_atoms]
    starting_coords_f32 = [Float32.(c) for c in starting_coords]
    starting_velocities_f32 = [Float32.(c) for c in starting_velocities]

    function test_sim(nl::Bool, parallel::Bool, gpu_diff_safe::Bool, f32::Bool, gpu::Bool)
        n_atoms = 400
        n_steps = 200
        atom_mass = f32 ? 10.0f0u"u" : 10.0u"u"
        box_size = f32 ? SVector(6.0f0, 6.0f0, 6.0f0)u"nm" : SVector(6.0, 6.0, 6.0)u"nm"
        simulator = VelocityVerlet(dt=f32 ? 0.02f0u"ps" : 0.02u"ps")
        b0 = f32 ? 0.2f0u"nm" : 0.2u"nm"
        kb = f32 ? 10_000.0f0u"kJ * mol^-1 * nm^-2" : 10_000.0u"kJ * mol^-1 * nm^-2"
        bonds = [HarmonicBond(b0=b0, kb=kb) for i in 1:(n_atoms ÷ 2)]
        specific_inter_lists = (InteractionList2Atoms(collect(1:2:n_atoms), collect(2:2:n_atoms),
                                repeat([""], length(bonds)), gpu ? cu(bonds) : bonds),)

        neighbor_finder = NoNeighborFinder()
        cutoff = DistanceCutoff(f32 ? 1.0f0u"nm" : 1.0u"nm")
        pairwise_inters = (LennardJones(nl_only=false, cutoff=cutoff),)
        if nl
            if gpu_diff_safe
                neighbor_finder = DistanceVecNeighborFinder(nb_matrix=gpu ? cu(trues(n_atoms, n_atoms)) : trues(n_atoms, n_atoms),
                                                            n_steps=10, dist_cutoff=f32 ? 1.5f0u"nm" : 1.5u"nm")
            else
                neighbor_finder = DistanceNeighborFinder(nb_matrix=trues(n_atoms, n_atoms), n_steps=10,
                                                            dist_cutoff=f32 ? 1.5f0u"nm" : 1.5u"nm")
            end
            pairwise_inters = (LennardJones(nl_only=true, cutoff=cutoff),)
        end
        show(devnull, neighbor_finder)

        if gpu
            coords = cu(deepcopy(f32 ? starting_coords_f32 : starting_coords))
            velocities = cu(deepcopy(f32 ? starting_velocities_f32 : starting_velocities))
            atoms = cu([Atom(charge=f32 ? 0.0f0 : 0.0, mass=atom_mass, σ=f32 ? 0.2f0u"nm" : 0.2u"nm",
                                ϵ=f32 ? 0.2f0u"kJ * mol^-1" : 0.2u"kJ * mol^-1") for i in 1:n_atoms])
        else
            coords = deepcopy(f32 ? starting_coords_f32 : starting_coords)
            velocities = deepcopy(f32 ? starting_velocities_f32 : starting_velocities)
            atoms = [Atom(charge=f32 ? 0.0f0 : 0.0, mass=atom_mass, σ=f32 ? 0.2f0u"nm" : 0.2u"nm",
                            ϵ=f32 ? 0.2f0u"kJ * mol^-1" : 0.2u"kJ * mol^-1") for i in 1:n_atoms]
        end

        s = System(
            atoms=atoms,
            pairwise_inters=pairwise_inters,
            specific_inter_lists=specific_inter_lists,
            coords=coords,
            velocities=velocities,
            box_size=box_size,
            neighbor_finder=neighbor_finder,
            gpu_diff_safe=gpu_diff_safe,
        )

        neighbors = find_neighbors(s; parallel=parallel)
        E_start = potential_energy(s, neighbors)

        simulate!(s, simulator, n_steps; parallel=parallel)
        return s.coords, E_start
    end

    runs = [
        ("in-place"        , [false, false, false, false, false]),
        ("in-place NL"     , [true , false, false, false, false]),
        ("in-place f32"    , [false, false, false, true , false]),
        ("out-of-place"    , [false, false, true , false, false]),
        ("out-of-place NL" , [true , false, true , false, false]),
        ("out-of-place f32", [false, false, true , true , false]),
    ]
    if run_parallel_tests
        push!(runs, ("in-place parallel"   , [false, true , false, false, false]))
        push!(runs, ("in-place NL parallel", [true , true , false, false, false]))
    end
    if run_gpu_tests
        push!(runs, ("out-of-place gpu"       , [false, false, true , false, true ]))
        push!(runs, ("out-of-place gpu f32"   , [false, false, true , true , true ]))
        push!(runs, ("out-of-place gpu NL"    , [true , false, true , false, true ]))
        push!(runs, ("out-of-place gpu f32 NL", [true , false, true , true , true ]))
    end

    final_coords_ref, E_start_ref = test_sim(runs[1][2]...)
    # Check all simulations give the same result to within some error
    for (name, args) in runs
        final_coords, E_start = test_sim(args...)
        final_coords_f64 = [Float64.(c) for c in Array(final_coords)]
        coord_diff = sum(sum(map(x -> abs.(x), final_coords_f64 .- final_coords_ref))) / (3 * n_atoms)
        E_diff = abs(Float64(E_start) - E_start_ref)
        @info "$(rpad(name, 20)) - difference per coordinate $coord_diff - potential energy difference $E_diff"
        @test coord_diff < 1e-4u"nm"
        @test E_diff < 1e-4u"kJ * mol^-1"
    end
end
