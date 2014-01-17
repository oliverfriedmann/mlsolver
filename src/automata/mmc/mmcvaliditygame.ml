open Tcsautomata;;
open Tcsautohelper;;
open Tcsautotransform;;
open Tcstransitionsys;;
open Tcsgames;;
open Tcsset;;
open Tcslist;;
open Tcsbasedata;;
open Tcsarray;;
open Tcstiming;;
open Tcsmessage;;
open Tcsmmcformula;;
open Mmcthreadnba;;
open Validitygames;;

type 'a state =
    TT
  | NT of int list
  | Tuple of ((int list) *            (* variables, branching *)
              (int list) *            (* modalities *)
			  (int list)) *           (* propositions *)
			  'a;;		              (* automaton *)

type 'a validity_game = 'a state initpg;;

type simplification_result = SimplTT | SimplFF | SimplKeep;;

let rec simplify ((_, fmls, prop, _) as fml) props i =
	match fmls.(i) with
		FIntAtom b -> if b then SimplTT else SimplFF
	|	FIntProp (b, p) -> if TreeSet.mem ((if b then fst else snd) (snd prop.(p))) props then SimplFF
	                       else if TreeSet.mem ((if b then snd else fst) (snd prop.(p))) props then SimplTT
						   else SimplKeep
	|	FIntBranch (true, l, r) -> (
			match simplify fml props l with
				SimplTT -> SimplTT
			|	SimplFF -> simplify fml props r
			|	SimplKeep -> if simplify fml props r = SimplTT then SimplTT else SimplKeep
		)
	|	FIntBranch (false, l, r) -> (
			match simplify fml props l with
				SimplFF -> SimplFF
			|	SimplTT -> simplify fml props r
			|	SimplKeep -> if simplify fml props r = SimplFF then SimplFF else SimplKeep
		)
	|	_ -> SimplKeep

let get_validity_game (((r, fmls, props, vars) as fml): decomposed_mmc_formula)
					   dpa
					   use_literal_propagation 
					   allow_removal_of_mu =

	let dpa_initial_state = DMA.initial dpa in
	let dpa_delta x y = DMA.delta dpa x y in
	let dpa_omega = DMA.accept dpa in
	let state_cmp = Domain.compare (DMA.states dpa) in
	let dpa_state_format = Domain.format (DMA.states dpa) in
					  
	let format_formula = format_decomposed_formula fml in
	
	let rec finish new_formulas = function
		TT -> TT
	|	NT s -> NT s
	|	Tuple ((a, b, c), d) -> (
		let (newa, newb, newc, is_true) = (ref [], ref [], ref [], ref false) in
		List.iter (fun f ->
			match fmls.(f) with
				FIntAtom b -> if b then is_true := true
			|	FIntModality _ -> newb := f::!newb
			|	FIntProp (b, p) -> newc := (f, (if b then snd else fst) (snd props.(p)))::!newc
			|	_ -> newa := f::!newa
		) new_formulas;
		if !is_true then TT else (
			let c = ref (TreeSet.of_list_def c) in
			List.iter (fun (f, f') ->
				if (TreeSet.mem f' !c) then is_true := true else c := TreeSet.add f !c
			) !newc;
			if !is_true then TT else (
				let a = TreeSet.elements (TreeSet.union (TreeSet.of_list_def !newa) (TreeSet.of_list_def a)) in
				let b = TreeSet.elements (TreeSet.union (TreeSet.of_list_def !newb) (TreeSet.of_list_def b)) in
				let c = TreeSet.elements !c in
				if (a = []) && (b = [])
				then NT c
				else Tuple ((a, b, c), d)
			)
		)
	)
	in
	
	let initial_state =	finish [r] (Tuple (([], [], []), dpa_initial_state)) in
	
	let exist_pos = function
		Tuple ((x::_, _, _), _) ->
			if allow_removal_of_mu then (
				match fmls.(x) with
					FIntVariable i ->
						let (nufp, _, _, _) = snd vars.(i) in
						not nufp
				|	_ -> false
			)
			else false
	|	_ -> true
	in
	
	let applyautom s d =
		match s with
			Tuple (x,_) -> Tuple (x,d)
		|	_ -> s
	in
	
	let rec delta = function
		Tuple ((a, b, c), d) -> (
		match a with
			f::a -> (
				match fmls.(f) with
					FIntVariable i -> 
						let (nufp, _, gua, f') = snd vars.(i) in
						let sd = dpa_delta d (Mmcthreadnba.Follow f) in
						let s = finish [f'] (Tuple ((a, b, c), d)) in
						if allow_removal_of_mu && (not nufp) && not gua
						then let td = dpa_delta d (Mmcthreadnba.Delete f) in
						     let t = finish [] (Tuple ((a,b,c), d)) in
						     [applyautom s sd; applyautom t td]
						else [applyautom s sd]
				|	FIntBranch (true, f1, f2) ->
						if use_literal_propagation then (
							let propsset = TreeSet.of_list_def c in
							let f1s = simplify fml propsset f1 in
							let f2s = simplify fml propsset f2 in
							if (f1s = SimplFF && f2s = SimplFF) then
								let sd = dpa_delta d (Mmcthreadnba.Delete f) in
								let s = finish [] (Tuple ((a, b, c), d)) in
								[applyautom s sd]
							else if (f1s = SimplTT || f2s = SimplTT) then
								[TT]
							else if (f1s = SimplFF || f2s = SimplFF) then
								let sd = dpa_delta d (Mmcthreadnba.Follow f) in
								let sd = dpa_delta sd (Mmcthreadnba.Delete (if f1s = SimplFF then f1 else f2)) in
								let s = finish [if f2s = SimplFF then f1 else f2] (Tuple ((a, b, c), d)) in
								[applyautom s sd]
							else
								let sd = dpa_delta d (Mmcthreadnba.Follow f) in
								let s = finish [f1; f2] (Tuple ((a, b, c), d)) in
								[applyautom s sd]
						)
						else
							let sd = dpa_delta d (Mmcthreadnba.Follow f) in
							let s = finish [f1; f2] (Tuple ((a, b, c), d)) in
							[applyautom s sd]
				|	FIntBranch (false, f1, f2) ->
						if use_literal_propagation then (
							let propsset = TreeSet.of_list_def c in
							let f1s = simplify fml propsset f1 in
							let f2s = simplify fml propsset f2 in
							if (f1s = SimplFF || f2s = SimplFF) then
								let sd = dpa_delta d (Mmcthreadnba.Delete f) in
								let s = finish [] (Tuple ((a, b, c), d)) in
								[applyautom s sd]
							else if (f1s = SimplTT && f2s = SimplTT) then
								[TT]
							else if (f1s = SimplTT || f2s = SimplTT) then
								let sd = dpa_delta d (Mmcthreadnba.Branch (f2s = SimplTT, f)) in
								let s = finish [if f2s = SimplTT then f1 else f2] (Tuple ((a, b, c), d)) in
								[applyautom s sd]
							else
								let d1 = dpa_delta d (Mmcthreadnba.Branch (true, f)) in
								let d2 = dpa_delta d (Mmcthreadnba.Branch (false, f)) in
								let s1 = finish [f1] (Tuple ((a, b, c), d)) in
								let s2 = finish [f2] (Tuple ((a, b, c), d)) in
								[applyautom s1 d1; applyautom s2 d2]
						)
						else
							let d1 = dpa_delta d (Mmcthreadnba.Branch (true, f)) in
							let d2 = dpa_delta d (Mmcthreadnba.Branch (false, f)) in
							let s1 = finish [f1] (Tuple ((a, b, c), d)) in
							let s2 = finish [f2] (Tuple ((a, b, c), d)) in
							[applyautom s1 d1 ; applyautom s2 d2]
				|	_ -> failwith "Mmcvaliditygame.delta: Failure 1!"
			)
		|	[] -> (
			if b = []
			then failwith "Mmcvaliditygame.delta: Failure 2!"
			else (
				let boxes = ref [] in
				let dias = ref [] in
				List.iter (fun f ->
					match fmls.(f) with
						(FIntModality (x,z)) ->
							if x then dias := z::!dias
							else boxes := (f,z)::!boxes
					|	_ -> failwith "Mmcvaliditygame.delta: Failure 3!"
				) b;
				if !boxes = [] then [NT c]
				else
				List.flatten (
					List.map (fun (boxf, boxc) ->
						let sd = dpa_delta d (Mmcthreadnba.Follow boxf) in
						let s = finish (boxc::!dias) (Tuple (([], [], []), d)) in
						[applyautom s sd]
					) !boxes )
				)
			)
	)
	|	s -> [s]
	in
	
	let omega = function
		TT -> 0
	|	NT _ -> 1
	|	Tuple (_, q) -> dpa_omega q
	in
	
	let format_state = function
		TT -> "TT"
	|	NT s -> "NT (" ^ ListUtils.format format_formula s ^ ")"
    |   Tuple ((a, b, c), f) -> "Tuple (" ^ ListUtils.format format_formula (a@b@c) ^ ", " ^ dpa_state_format f ^ ")"
	in
	
	let comp' cmp s1 s2 = match (s1, s2) with
		(Tuple (a, x), Tuple (b, y)) -> (
			let c = compare a b in
			if c = 0 then cmp x y else c
		)
	|	_ -> compare s1 s2
	in
		
	let comp =
		Some (comp' state_cmp)
	in

	((initial_state, delta, omega, exist_pos, format_state),
	 (None, None, comp))
	 
	 
let extract_counter_model (dec_formula: decomposed_mmc_formula)
                          validity_game strategy int_to_state state_to_int =
	let (_, fmls, props, _) = dec_formula in
	let ((init, delta, _, ex, fo), _) = validity_game in

	let props_final i = fst props.(i) in
	
	let rec finalize i =
		match (fst (int_to_state i)) with
			TT -> i
		|	NT _ -> i
		|	Tuple (([], _, _), _) -> i
		|	_ -> finalize (if ex i then List.hd (delta i) else OptionUtils.get_some (strategy i))
	in
				 
	let init_final = finalize init in
	
	let get_props_final i =
		let convert l =
			List.filter (fun i -> i >= 0)
				(List.map (fun f ->
					match fmls.(f) with
						FIntProp (false, p) -> p
					|	_ -> -1
				) l)
		in
		match (fst (int_to_state i)) with
			TT -> []
		|	NT l -> convert l
		|	Tuple ((_, _, l), _) -> convert l
	in
			 
	let get_delta_final i =
		match (fst (int_to_state i)) with
			Tuple (([], _, _), _) ->
				List.map finalize (delta i)
		|	_ -> []
	in
		
	let get_annot_final i = fo i in
	
	let compare_final i j = compare i j in
	
	((init_final, get_props_final, get_delta_final, get_annot_final),
	 (Some compare_final, props_final))

	 
let compare_formula f g =
	match (f, g) with
		(FIntBranch (true, _, _), FIntBranch (false, _, _)) -> -1
	|	(FIntBranch (false, _, _), FIntBranch (true, _, _)) -> 1
	|	_ -> compare f g;;


let validity_proc formula options (info_chan, formula_chan, constr_chan) =
	let proof_game_in_annot = ArrayUtils.mem "ann" options in
	let compact_game = ArrayUtils.mem "comp" options in
	let use_literal_propagation = ArrayUtils.mem "litpro" options in
	let without_guardedness = ArrayUtils.mem "woguarded" options in
	let length_sort =
		if ArrayUtils.mem "prefersmall" options then 1
		else if ArrayUtils.mem "preferlarge" options then -1
		else 0
	in
	let info_msg = MessageChannel.send_message info_chan in
	let formula_msg = MessageChannel.send_message formula_chan in
	let constr_msg = MessageChannel.send_message constr_chan in
	
	info_msg (fun _ -> "Decision Procedure For Modal Mu Calculus\n");
	
	formula_msg (fun _ -> "Transforming given formula...");
    let t = SimpleTiming.init true in
	let formula' = eval_metaformula formula in
    let goalformula' = make_uniquely_bound (formula_to_positive formula') in
    let goalformula = if is_guarded goalformula' || without_guardedness then goalformula' else make_uniquely_bound (guarded_transform goalformula') in
	formula_msg (fun _ -> SimpleTiming.format t ^ "\n");
	formula_msg (fun _ -> "Transformed formula: " ^ format_formula goalformula ^ "\n");
	formula_msg (fun _ -> "Formula Length: " ^ string_of_int (formula_length goalformula) ^ "\n");
	
	constr_msg (fun _ -> "Decompose formula...");
    let t = SimpleTiming.init true in
    let decformula = normal_form_formula_to_decomposed_formula goalformula in
	let decformula = 
		if length_sort = 0
		then sort_decomposed_formula decformula (fun _ -> compare_formula)
		else sort_decomposed_formula decformula (fun d a b -> length_sort * compare (get_formula_depth d a) (get_formula_depth d b))
	in
	constr_msg (fun _ -> SimpleTiming.format t ^ "\n");
	formula_msg (fun _ -> "Subformula Cardinality: " ^ string_of_int (decomposed_formula_subformula_cardinality decformula) ^ "\n");

	constr_msg (fun _ -> "Initializing automata...");
    let t = SimpleTiming.init true in
	
	let timing_list = ref [] in
	let new_timing s =
		let t = SimpleTiming.init false in
		timing_list := (s, t)::!timing_list;
		t
	in
	
	let listening = MessageChannel.channel_is_listening constr_chan in

	let nba_without_timing = mmc_thread_nba decformula in
	let nba = if listening then NMATiming.full_timing nba_without_timing (new_timing "nba_timing") else nba_without_timing in

	let nba_state_cache = NMAStateCache.make2 nba in
	let nba_delta_cache = NMADeltaCache.make (NMAStateCache.automaton2 nba_state_cache) in
	let nba_accept_cache = NMAAcceptCache.make (NMADeltaCache.automaton nba_delta_cache) in
	let nba_cached_without_timing = NMAAcceptCache.automaton nba_accept_cache in		
	let nba_cached = if listening then NMATiming.full_timing nba_cached_without_timing (new_timing "nba_cached_timing") else nba_cached_without_timing in
	
	let dpa_without_timing = NBAtoDPA.transform nba_cached (mmc_thread_nba_state_size decformula) in
	let dpa = if listening then DMATiming.full_timing dpa_without_timing (new_timing "dpa_timing") else dpa_without_timing in

	let dpa_state_cache = DMAStateCache.make2 dpa in
	let dpa_delta_cache = DMADeltaCache.make (DMAStateCache.automaton2 dpa_state_cache) in
	let dpa_accept_cache = DMAAcceptCache.make (DMADeltaCache.automaton dpa_delta_cache) in
	let dpa_cached_without_timing = DMAAcceptCache.automaton dpa_accept_cache in
	let dpa_cached = if listening then DMATiming.full_timing dpa_cached_without_timing (new_timing "dpa_cached_timing") else dpa_cached_without_timing in

	let states_nba _ = NMAStateCache.state_size2 nba_state_cache in
	let transitions_nba _ = NMADeltaCache.edge_size nba_delta_cache in
	let states_dpa _ = DMAStateCache.state_size2 dpa_state_cache in
	let transitions_dpa _ = DMADeltaCache.edge_size dpa_delta_cache in
	let states_game = ref 0 in
	let info_list = [("nba_states", states_nba); ("nba_transitions", transitions_nba);
				     ("dpa_states", states_dpa); ("dpa_transitions", transitions_dpa);
				     ("game_states", fun () -> !states_game)] in

	let game =
		let temp = get_validity_game decformula dpa_cached use_literal_propagation (without_guardedness && not (is_guarded goalformula)) in
		let temp = if compact_game then get_compact_initpg_by_player temp false else get_escaped_initpg temp 0 in
		if listening then get_timed_initpg temp (new_timing "game_timing") else temp
	in
	let (game_cached, state_to_int, int_to_state) = (
		let (temp, state_to_int, int_to_state) = get_int_cached_initpg game (fun _ i -> states_game := i) in
		((if listening then get_timed_initpg temp (new_timing "game_cached_timing") else temp),
		 state_to_int, int_to_state)
	)
	in
  	constr_msg (fun _ -> SimpleTiming.format t ^ "\n");
	
    let ((init, b, c, d, fo), e) = game_cached in

	let fo' = if proof_game_in_annot
	          then (fun s -> fo s)
			  else (fun _ -> "")
	in

	let game_cached' = ((init, b, c, d, fo'), e) in
	
	
	let show_stats _ =
		if listening then (
			List.iter (fun (s, v) ->
				constr_msg (fun _ -> s ^ ": " ^ string_of_int (v ()) ^ "\n")
			) info_list;
			List.iter (fun (s, t) ->
				constr_msg (fun _ -> s ^ ": " ^ (SimpleTiming.format t) ^ "\n")
			) !timing_list
		);
		info_msg (fun _ -> "Game has " ^ string_of_int !states_game ^ " states (NBA " ^ string_of_int (states_nba ()) ^ " , DPA " ^ string_of_int (states_dpa ()) ^ ").\n");
	in
	
	let counter_mod strategy printer =
		info_msg (fun _ -> "Extracting Transition System.\n");
		constr_msg (fun _ -> "Building Transition System...\n");
		let t = SimpleTiming.init true in
		let ts = extract_counter_model decformula game_cached strategy int_to_state state_to_int in
		let ((_, _, _, fo), _) = ts in
		let states_ts = ref 0 in
		let (ts_cached, ts_state_to_int, ts_int_to_state) = 
			get_int_cached_initts ts (fun _ i -> states_ts := i) in
		let fmt = if proof_game_in_annot
				  then (fun s -> Some (fo s))
				  else (fun _ -> None)
		in
		let explicit_ts = build_explicit_initts ts_cached ts_int_to_state fmt (fun i ->
			if (i mod 1000 = 0)
			then constr_msg (fun _ -> "\rBuilding..." ^ string_of_int i)
		) in
		constr_msg (fun _ -> "\rBuilding... finished in " ^ SimpleTiming.format t ^ "\n\n");
		let (_, (_, graph)) = explicit_ts in
		info_msg (fun _ -> "Transition System has " ^ string_of_int (Array.length graph) ^ " states.\n");
		print_explicit_initts explicit_ts printer
	in
	
   (game_cached', show_stats, (fun sol strat -> if sol init = Some true then FormulaValid else FormulaFalsifiableBy (counter_mod strat)));;
	
Validitygames.register_validity_procedure validity_proc "mmc" "Decision Procedure For Modal Mu Calculus"
