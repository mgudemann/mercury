%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2015 The Mercury team.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

:- module hlds.make_hlds.add_foreign_proc.
:- interface.

:- import_module hlds.hlds_module.
:- import_module hlds.hlds_pred.
:- import_module parse_tree.error_util.
:- import_module parse_tree.prog_item.

:- import_module list.

:- pred add_pragma_foreign_proc_export(item_maybe_attrs::in,
    pragma_info_foreign_proc_export::in, prog_context::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

:- pred add_pragma_foreign_proc(pragma_info_foreign_proc::in,
    import_status::in, prog_context::in, maybe(int)::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module backend_libs.
:- import_module backend_libs.foreign.
:- import_module hlds.hlds_error_util.
:- import_module hlds.hlds_args.
:- import_module hlds.hlds_code_util.
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_rtti.
:- import_module hlds.make_hlds.make_hlds_error.
:- import_module hlds.make_hlds.make_hlds_warn.
:- import_module hlds.pred_table.
:- import_module hlds.quantification.
:- import_module libs.
:- import_module libs.options.
:- import_module mdbcomp.
:- import_module mdbcomp.sym_name.
:- import_module parse_tree.mercury_to_mercury.
:- import_module parse_tree.prog_foreign.
:- import_module parse_tree.prog_ctgc.
:- import_module parse_tree.prog_out.
:- import_module parse_tree.prog_util.

:- import_module assoc_list.
:- import_module bag.
:- import_module cord.
:- import_module int.
:- import_module map.
:- import_module pair.
:- import_module require.
:- import_module string.

%-----------------------------------------------------------------------------%

add_pragma_foreign_proc_export(MaybeAttrs, FPEInfo, Context,
        !ModuleInfo, !Specs) :-
    FPEInfo = pragma_info_foreign_proc_export(Lang, PrednameModesPF,
        ExportedName),
    PrednameModesPF = pred_name_modes_pf(Name, Modes, PredOrFunc),
    module_info_get_predicate_table(!.ModuleInfo, PredTable),
    list.length(Modes, Arity),
    predicate_table_lookup_pf_sym_arity(PredTable, may_be_partially_qualified,
        PredOrFunc, Name, Arity, PredIds),
    (
        PredIds = [],
        (
            MaybeAttrs = item_origin_user,
            undefined_pred_or_func_error(Name, Arity, Context,
                [pragma_decl("foreign_export"), words("declaration")],
                !Specs)
        ;
            MaybeAttrs = item_origin_compiler(CompilerAttrs),
            % We do not warn about errors in export pragmas created by
            % the compiler as part of a source-to-source transformation.
            CompilerAttrs = item_compiler_attributes(AllowExport, _IsMutable),
            (
                AllowExport = do_allow_export
            ;
                AllowExport = do_not_allow_export,
                unexpected($module, $pred,
                    "bad introduced foreign_export pragma")
            )
        )
    ;
        PredIds = [PredId],
        add_pragma_foreign_proc_export_2(Arity, PredTable, MaybeAttrs,
            Lang, Name, PredId, Modes, ExportedName, Context,
            !ModuleInfo, !Specs)
    ;
        PredIds = [_, _ | _],
        StartPieces = [words("Error: ambiguous"), p_or_f(PredOrFunc),
            words("name in"), pragma_decl("foreign_export"),
            words("declaration."), nl,
            words("The possible matches are:"), nl_indent_delta(1)],
        PredIdPiecesList = list.map(
            describe_one_pred_name(!.ModuleInfo, should_module_qualify),
            PredIds),
        PredIdPieces = component_list_to_line_pieces(PredIdPiecesList,
            [suffix(".")]),
        MainPieces = StartPieces ++ PredIdPieces,
        VerbosePieces = [words("An explicit module qualifier"),
            words("may be necessary.")],
        Msg = simple_msg(Context,
            [always(MainPieces), verbose_only(verbose_always, VerbosePieces)]),
        Spec = error_spec(severity_error, phase_parse_tree_to_hlds, [Msg]),
        !:Specs = [Spec | !.Specs]
    ).

:- pred add_pragma_foreign_proc_export_2(arity::in, predicate_table::in,
    item_maybe_attrs::in, foreign_language::in,
    sym_name::in, pred_id::in, list(mer_mode)::in, string::in,
    prog_context::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

add_pragma_foreign_proc_export_2(Arity, PredTable, MaybeAttrs, Lang, Name,
        PredId, Modes, ExportedName, Context, !ModuleInfo, !Specs) :-
    predicate_table_get_preds(PredTable, Preds),
    map.lookup(Preds, PredId, PredInfo),
    pred_info_get_proc_table(PredInfo, Procs),
    map.to_assoc_list(Procs, ExistingProcs),
    (
        get_procedure_matching_declmodes_with_renaming(ExistingProcs,
            Modes, !.ModuleInfo, ProcId)
    ->
        map.lookup(Procs, ProcId, ProcInfo0),
        proc_info_get_declared_determinism(ProcInfo0, MaybeDetism),
        % We cannot catch those multi or nondet procedures that don't have
        % a determinism declaration until after determinism analysis.
        (
            MaybeDetism = yes(Detism),
            ( Detism = detism_non
            ; Detism = detism_multi
            )
        ->
            Pieces = [words("Error:"),
                pragma_decl("foreign_export"), words("declaration"),
                words("for a procedure that has"),
                words("a declared determinism of"),
                fixed(determinism_to_string(Detism) ++ "."), nl],
            Msg = simple_msg(Context, [always(Pieces)]),
            Spec = error_spec(severity_error, phase_parse_tree_to_hlds,
                [Msg]),
            !:Specs = [Spec | !.Specs]
        ;
            % Only add the foreign export if the specified language matches
            % one of the foreign languages available for this backend.
            %
            module_info_get_globals(!.ModuleInfo, Globals),
            globals.get_backend_foreign_languages(Globals, ForeignLanguages),
            ( list.member(Lang, ForeignLanguages) ->
                module_info_get_pragma_exported_procs(!.ModuleInfo,
                    PragmaExportedProcs0),
                NewExportedProc = pragma_exported_proc(Lang,
                    PredId, ProcId, ExportedName, Context),
                PragmaExportedProcs =
                    cord.snoc(PragmaExportedProcs0, NewExportedProc),
                module_info_set_pragma_exported_procs(PragmaExportedProcs,
                    !ModuleInfo)
            ;
                true
            ),

            % Record that there was a foreign_export pragma for this procedure,
            % regardless of the specified language. We do this so that dead
            % procedure elimination does not generate incorrect warnings about
            % dead procedures (e.g. those that are foreign_exported to
            % languages other than those languages that are supported by the
            % current backend.)
            %
            proc_info_set_has_any_foreign_exports(has_foreign_exports,
                ProcInfo0, ProcInfo),
            module_info_set_pred_proc_info(PredId, ProcId, PredInfo, ProcInfo,
                !ModuleInfo)
        )
    ;
        (
            MaybeAttrs = item_origin_user,
            undefined_mode_error(Name, Arity, Context,
                [pragma_decl("foreign_export"), words("declaration")],
                !Specs)
        ;
            MaybeAttrs = item_origin_compiler(CompilerAttrs),
            % We do not warn about errors in export pragmas created by
            % the compiler as part of a source-to-source transformation.
            CompilerAttrs = item_compiler_attributes(AllowExport, _IsMutable),
            (
                AllowExport = do_allow_export
            ;
                AllowExport = do_not_allow_export,
                unexpected($module, $pred,
                    "bad introduced foreign_export pragma")
            )
        )
    ).

%-----------------------------------------------------------------------------%

add_pragma_foreign_proc(FPInfo, Status, Context, MaybeItemNumber,
        !ModuleInfo, !Specs) :-
    FPInfo = pragma_info_foreign_proc(Attributes0, PredName, PredOrFunc,
        PVars, ProgVarSet, _InstVarset, PragmaImpl),

    % Begin by replacing any maybe_thread_safe foreign_proc attributes
    % with the actual thread safety attributes which we get from the
    % `--maybe-thread-safe' option.

    module_info_get_globals(!.ModuleInfo, Globals),
    globals.get_maybe_thread_safe(Globals, MaybeThreadSafe),
    ThreadSafe = get_thread_safe(Attributes0),
    (
        ThreadSafe = proc_maybe_thread_safe,
        (
            MaybeThreadSafe = yes,
            set_thread_safe(proc_thread_safe, Attributes0, Attributes)
        ;
            MaybeThreadSafe = no,
            set_thread_safe(proc_not_thread_safe, Attributes0, Attributes)
        )
    ;
        ( ThreadSafe = proc_thread_safe
        ; ThreadSafe = proc_not_thread_safe
        ),
        Attributes = Attributes0
    ),
    module_info_get_name(!.ModuleInfo, ModuleName),
    PragmaForeignLanguage = get_foreign_language(Attributes),
    list.length(PVars, Arity),
    globals.lookup_bool_option(Globals, very_verbose, VeryVerbose),
    (
        VeryVerbose = yes,
        trace [io(!IO)] (
            io.write_string("% Processing `:- pragma foreign_proc' for ", !IO),
            write_simple_call_id(PredOrFunc, PredName/Arity, !IO),
            io.write_string("...\n", !IO)
        )
    ;
        VeryVerbose = no
    ),

    globals.get_backend_foreign_languages(Globals, BackendForeignLangs),

    % Lookup the pred declaration in the predicate table.
    % If it is not there, print an error message and insert
    % a dummy declaration for the predicate.
    module_info_get_predicate_table(!.ModuleInfo, PredTable0),
    predicate_table_lookup_pf_sym_arity(PredTable0, is_fully_qualified,
        PredOrFunc, PredName, Arity, PredIds),
    (
        PredIds = [],
        preds_add_implicit_report_error(!ModuleInfo, ModuleName,
            PredName, Arity, PredOrFunc, Status, no, Context,
            origin_user(PredName),
            [pragma_decl("foreign_proc"), words("declaration")],
            PredId, !Specs)
    ;
        PredIds = [PredId]
    ;
        PredIds = [PredId, _ | _],
        % Any attempt to define more than one pred with the same PredOrFunc,
        % PredName and Arity should have been caught earlier, and an error
        % message generated. We continue so that we can try to find more
        % errors.
        AmbiPieces = [words("Error: ambiguous predicate name"),
            simple_call(simple_call_id(PredOrFunc, PredName, Arity)),
            words("in"), quote("pragma foreign_proc"), suffix("."), nl],
        AmbiMsg = simple_msg(Context, [always(AmbiPieces)]),
        AmbiSpec = error_spec(severity_error, phase_parse_tree_to_hlds,
            [AmbiMsg]),
        !:Specs = [AmbiSpec | !.Specs]
    ),

    % Lookup the pred_info for this pred, add the pragma to the proc_info
    % in the proc_table in the pred_info, and save the pred_info.
    module_info_get_predicate_table(!.ModuleInfo, PredTable1),
    predicate_table_get_preds(PredTable1, Preds0),
    some [!PredInfo] (
        map.lookup(Preds0, PredId, !:PredInfo),

        % status_opt_imported preds are initially tagged as status_imported
        % and are tagged as status_opt_imported only if/when we see a clause
        % (including a `foreign_proc' clause) for them.
        ( Status = status_opt_imported ->
            pred_info_set_import_status(status_opt_imported, !PredInfo)
        ;
            true
        ),

        % Record the existence of this "clause".
        pred_info_get_clauses_info(!.PredInfo, ClausesInfo0),
        ItemNumbers0 = ClausesInfo0 ^ cli_item_numbers,
        add_clause_item_number(MaybeItemNumber, Context, item_is_foreign_proc,
            ItemNumbers0, ItemNumbers),
        ClausesInfo1 = ClausesInfo0 ^ cli_item_numbers := ItemNumbers,
        pred_info_set_clauses_info(ClausesInfo1, !PredInfo),
        module_info_set_pred_info(PredId, !.PredInfo, !ModuleInfo),

        PredInfo0 = !.PredInfo,

        CurrentBackend = lookup_current_backend(Globals),
        ExtraAttrs = get_extra_attributes(Attributes),
        (
            is_applicable_for_current_backend(CurrentBackend, ExtraAttrs) = no
        ->
            % Ignore this foreign_proc.
            true
        ;
            pred_info_is_imported(!.PredInfo)
        ->
            Pieces = [words("Error:"), pragma_decl("foreign_proc"),
                words("declaration for imported"),
                simple_call(simple_call_id(PredOrFunc, PredName, Arity)),
                suffix("."), nl],
            Msg = simple_msg(Context, [always(Pieces)]),
            Spec = error_spec(severity_error, phase_parse_tree_to_hlds, [Msg]),
            !:Specs = [Spec | !.Specs]
        ;
            % Don't add clauses for foreign languages other than the ones
            % we can generate code for.
            not list.member(PragmaForeignLanguage, BackendForeignLangs)
        ->
            pred_info_update_goal_type(goal_type_foreign,
                PredInfo0, !:PredInfo),
            module_info_set_pred_info(PredId, !.PredInfo, !ModuleInfo)
        ;
            % Add the pragma declaration to the proc_info for this procedure.
            pred_info_get_proc_table(!.PredInfo, Procs),
            map.to_assoc_list(Procs, ExistingProcs),
            pragma_get_modes(PVars, Modes),
            SimpleCallId = simple_call_id(PredOrFunc, PredName, Arity),
            (
                % The inst variables for the foreign_proc declaration
                % and predmode declarations are from different varsets.
                % We cannot just unify the argument modes directly because
                % the representation of the inst variables may be different.
                % Instead we need to allow for a renaming between the
                % inst variables in the argument modes of the foreign_proc
                % and those of the predmode declaration.
                %
                % XXX We should probably also check that each pair in
                % the renaming has the same name.
                get_procedure_matching_declmodes_with_renaming(ExistingProcs,
                    Modes, !.ModuleInfo, ProcId)
            ->
                pred_info_get_arg_types(!.PredInfo, ArgTypes),
                pred_info_get_purity(!.PredInfo, Purity),
                pred_info_get_markers(!.PredInfo, Markers),
                clauses_info_add_pragma_foreign_proc(Purity, Attributes,
                    PredId, ProcId, ProgVarSet, PVars, ArgTypes, PragmaImpl,
                    Context, PredOrFunc, PredName, Arity, Markers,
                    ClausesInfo1, ClausesInfo, !ModuleInfo, !Specs),
                pred_info_set_clauses_info(ClausesInfo, !PredInfo),
                pred_info_update_goal_type(goal_type_foreign, !PredInfo),
                map.det_update(PredId, !.PredInfo, Preds0, Preds),
                predicate_table_set_preds(Preds, PredTable1, PredTable),
                module_info_set_predicate_table(PredTable, !ModuleInfo),
                pragma_get_var_infos(PVars, ArgInfoBox),
                assoc_list.keys(ArgInfoBox, ArgInfo),
                warn_singletons_in_pragma_foreign_proc(!.ModuleInfo,
                    PragmaImpl, PragmaForeignLanguage, ArgInfo, Context,
                    SimpleCallId, PredId, ProcId, !Specs)
            ;
                Pieces = [words("Error:"),
                    pragma_decl("foreign_proc"), words("declaration"),
                    words("for undeclared mode of"),
                    simple_call(SimpleCallId), suffix("."), nl],
                Msg = simple_msg(Context, [always(Pieces)]),
                Spec = error_spec(severity_error, phase_parse_tree_to_hlds,
                    [Msg]),
                !:Specs = [Spec | !.Specs]
            )
        )
    ).

:- func is_applicable_for_current_backend(backend,
    list(pragma_foreign_proc_extra_attribute)) = bool.

is_applicable_for_current_backend(_CurrentBackend, []) = yes.
is_applicable_for_current_backend(CurrentBackend, [Attr | Attrs]) = Result :-
    (
        ( Attr = max_stack_size(_)
        ; Attr = refers_to_llds_stack
        ; Attr = needs_call_standard_output_registers
        ),
        Result = is_applicable_for_current_backend(CurrentBackend, Attrs)
    ;
        Attr = backend(Backend),
        ( Backend = CurrentBackend ->
            Result = is_applicable_for_current_backend(CurrentBackend, Attrs)
        ;
            Result = no
        )
    ).

    % Add the pragma_foreign_proc goal to the clauses_info for this procedure.
    % To do so, we must also insert unifications between the variables in the
    % pragma foreign_proc declaration and the head vars of the pred. Also
    % return the hlds_goal.
    %
:- pred clauses_info_add_pragma_foreign_proc(purity::in,
    pragma_foreign_proc_attributes::in, pred_id::in, proc_id::in,
    prog_varset::in, list(pragma_var)::in, list(mer_type)::in,
    pragma_foreign_proc_impl::in, prog_context::in,
    pred_or_func::in, sym_name::in, arity::in, pred_markers::in,
    clauses_info::in, clauses_info::out, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

clauses_info_add_pragma_foreign_proc(Purity, Attributes0,
        PredId, ProcId, PVarSet, PVars, OrigArgTypes, PragmaImpl0,
        Context, PredOrFunc, PredName, Arity, Markers,
        !ClausesInfo, !ModuleInfo, !Specs) :-
    module_info_pred_info(!.ModuleInfo, PredId, PredInfo),
    ( pred_info_is_builtin(PredInfo) ->
        % When bootstrapping a change that defines a builtin using
        % normal Mercury code, we need to disable the generation
        % of the error message, and just ignore the definition.
        module_info_get_globals(!.ModuleInfo, Globals),
        globals.lookup_bool_option(Globals, allow_defn_of_builtins,
            AllowDefnOfBuiltin),
        (
            AllowDefnOfBuiltin = no,
            Msg = simple_msg(Context,
                [always([words("Error: foreign_proc for builtin."), nl])]),
            Spec = error_spec(severity_error, phase_parse_tree_to_hlds, [Msg]),
            !:Specs = [Spec | !.Specs]
        ;
            AllowDefnOfBuiltin = yes
        )
    ;
        AllProcIds = pred_info_all_procids(PredInfo),
        clauses_info_do_add_pragma_foreign_proc(Purity, Attributes0,
            PredId, ProcId, AllProcIds, PVarSet, PVars, OrigArgTypes,
            PragmaImpl0, Context, PredOrFunc, PredName, Arity,
            Markers, !ClausesInfo, !ModuleInfo, !Specs)
    ).

:- pred clauses_info_do_add_pragma_foreign_proc(purity::in,
    pragma_foreign_proc_attributes::in, pred_id::in, proc_id::in,
    list(proc_id)::in, prog_varset::in, list(pragma_var)::in,
    list(mer_type)::in, pragma_foreign_proc_impl::in, prog_context::in,
    pred_or_func::in, sym_name::in, arity::in, pred_markers::in,
    clauses_info::in, clauses_info::out, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

clauses_info_do_add_pragma_foreign_proc(Purity, Attributes0,
        PredId, ProcId, AllProcIds, PVarSet, PVars, OrigArgTypes, PragmaImpl0,
        Context, PredOrFunc, PredName, Arity, Markers,
        !ClausesInfo, !ModuleInfo, !Specs) :-
    % Our caller should have already added this foreign_proc to ItemNumbers.
    !.ClausesInfo = clauses_info(VarSet0, ExplicitVarTypes, TVarNameMap,
        InferredVarTypes, HeadVars, ClauseRep, ItemNumbers,
        RttiVarMaps, _HasForeignClauses),

    get_clause_list(ClauseRep, Clauses),

    % Currently we can override Mercury clauses with a foreign_proc right here,
    % which means that semantic analysis never sees those Mercury clauses.
    % Any errors in them thus do get picked not when they first arise, but
    % only when the code gets compiled for a target that requires their use.
    % XXX We should retain and check the Mercury clauses, and override them
    % with a more specific foreign language implementation only after semantic
    % analysis.
    module_info_get_globals(!.ModuleInfo, Globals),
    globals.get_target(Globals, Target),
    NewLang = get_foreign_language(Attributes0),
    add_foreign_proc_update_existing_clauses(PredName, Arity, PredOrFunc,
        Context, Globals, Target, NewLang, AllProcIds, ProcId,
        Clauses, NewClauses0, Overridden, !Specs),

    globals.get_backend_foreign_languages(Globals, BackendForeignLanguages),
    pragma_get_vars(PVars, Args0),
    pragma_get_var_infos(PVars, ArgInfo),

    % If the foreign language not one of the backend languages, we will
    % have to generate an interface to it in a backend language.
    foreign.extrude_pragma_implementation(BackendForeignLanguages,
        PVars, PredName, PredOrFunc, Context, !ModuleInfo,
        Attributes0, Attributes1, PragmaImpl0, PragmaImpl),

    % Check for arguments occurring more than once.
    bag.init(ArgBag0),
    bag.insert_list(Args0, ArgBag0, ArgBag),
    bag.to_assoc_list(ArgBag, ArgBagAL0),
    list.filter(
        (pred(Arg::in) is semidet :-
            Arg = _ - Occurrences,
            Occurrences > 1
        ), ArgBagAL0, ArgBagAL),
    assoc_list.keys(ArgBagAL, MultipleArgs),

    (
        MultipleArgs = [_ | _],
        adjust_func_arity(PredOrFunc, OrigArity, Arity),
        SimpleCallId = simple_call_id(PredOrFunc, PredName, OrigArity),
        Pieces1 = [words("In"), pragma_decl("foreign_proc"),
            words("declaration for"), simple_call(SimpleCallId),
            suffix(":"), nl],
        (
            MultipleArgs = [MultipleArg],
            Pieces2 = [words("error: variable"),
                quote(mercury_var_to_string(PVarSet, no, MultipleArg)),
                words("occurs multiple times in the argument list."), nl]
        ;
            MultipleArgs = [_, _ | _],
            Pieces2 = [words("error: variables"),
                quote(mercury_vars_to_string(PVarSet, no, MultipleArgs)),
                words("occur multiple times in the argument list."), nl]
        ),
        Msg = simple_msg(Context, [always(Pieces1 ++ Pieces2)]),
        Spec = error_spec(severity_error, phase_parse_tree_to_hlds, [Msg]),
        !:Specs = [Spec | !.Specs]
    ;
        MultipleArgs = [],
        % Build the foreign_proc.
        goal_info_init(GoalInfo0),
        goal_info_set_context(Context, GoalInfo0, GoalInfo1),

        % Check that the purity of a predicate/function declaration agrees
        % with the (promised) purity of the foreign proc. We do not perform
        % this check if there is a promise_{pure,semipure} pragma for the
        % predicate/function, since in that case they will differ anyway.
        (
            ( check_marker(Markers, marker_promised_pure)
            ; check_marker(Markers, marker_promised_semipure)
            )
        ->
            true
        ;
            ForeignAttributePurity = get_purity(Attributes1),
            ( ForeignAttributePurity = Purity ->
                true
            ;
                purity_name(ForeignAttributePurity, ForeignAttributePurityStr),
                purity_name(Purity, PurityStr),
                Pieces = [words("Error: foreign clause for"),
                    p_or_f(PredOrFunc), sym_name_and_arity(PredName / Arity),
                    words("has purity"), words(ForeignAttributePurityStr),
                    words("but that"), p_or_f(PredOrFunc),
                    words("has been declared"), words(PurityStr),
                    suffix("."), nl],
                Msg = simple_msg(Context, [always(Pieces)]),
                Spec = error_spec(severity_error, phase_parse_tree_to_hlds,
                    [Msg]),
                !:Specs = [Spec | !.Specs]
            )
        ),
        (
            Overridden = overridden_by_old_foreign_proc
        ;
            Overridden = not_overridden_by_old_foreign_proc,

            % Put the purity in the goal_info in case this foreign code is
            % inlined.
            goal_info_set_purity(Purity, GoalInfo1, GoalInfo),
            % XXX ARGVEC - the foreign_args field in the hlds_goal_expr type
            % should also be a an proc_arg_vector rather than a list.
            HeadVarList = proc_arg_vector_to_list(HeadVars),
            make_foreign_args(HeadVarList, ArgInfo, OrigArgTypes, ForeignArgs),
            % Perform some renaming in any user annotated sharing information.
            maybe_rename_user_annotated_sharing_information(Globals,
                Args0, HeadVarList, OrigArgTypes, Attributes1, Attributes),
            ExtraArgs = [],
            MaybeTraceRuntimeCond = no,
            GoalExpr = call_foreign_proc(Attributes, PredId, ProcId,
                ForeignArgs, ExtraArgs, MaybeTraceRuntimeCond, PragmaImpl),
            HldsGoal0 = hlds_goal(GoalExpr, GoalInfo),
            init_vartypes(EmptyVarTypes),
            rtti_varmaps_init(EmptyRttiVarmaps),
            implicitly_quantify_clause_body_general(
                ordinary_nonlocals_maybe_lambda, HeadVarList, _Warnings,
                HldsGoal0, HldsGoal, VarSet0, VarSet, EmptyVarTypes, _,
                EmptyRttiVarmaps, _),
            NewClause = clause(selected_modes([ProcId]), HldsGoal,
                impl_lang_foreign(NewLang), Context, []),
            NewClauses = [NewClause | NewClauses0],
            HasForeignClauses = yes,
            set_clause_list(NewClauses, NewClauseRep),
            !:ClausesInfo = clauses_info(VarSet, ExplicitVarTypes, TVarNameMap,
                InferredVarTypes, HeadVars, NewClauseRep, ItemNumbers,
                RttiVarMaps, HasForeignClauses)
        )
    ).

    % Rename any user annotated structure sharing information from the
    % variables (incl. type variables) in terms of which that information
    % is expressed, to the formal variables in terms of which the clause
    % is expressed.
    %
:- pred maybe_rename_user_annotated_sharing_information(globals::in,
    list(prog_var)::in, list(prog_var)::in, list(mer_type)::in,
    pragma_foreign_proc_attributes::in, pragma_foreign_proc_attributes::out)
    is det.

maybe_rename_user_annotated_sharing_information(Globals,
        ActualHeadVars, FormalHeadVars, FormalTypes, !Attributes):-
    globals.lookup_bool_option(Globals, structure_sharing_analysis,
        SharingAnalysis),
    (
        SharingAnalysis = no
    ;
        SharingAnalysis = yes,
        rename_user_annotated_sharing(ActualHeadVars, FormalHeadVars,
            FormalTypes, get_user_annotated_sharing(!.Attributes),
            FormalUserSharing),
        set_user_annotated_sharing(FormalUserSharing, !Attributes)
    ).

:- type overridden_by_old_foreign_proc
    --->    overridden_by_old_foreign_proc
    ;       not_overridden_by_old_foreign_proc.

:- pred add_foreign_proc_update_existing_clauses(sym_name::in, arity::in,
    pred_or_func::in, prog_context::in, globals::in, compilation_target::in,
    foreign_language::in, list(proc_id)::in, proc_id::in,
    list(clause)::in, list(clause)::out,
    overridden_by_old_foreign_proc::out,
    list(error_spec)::in, list(error_spec)::out) is det.

add_foreign_proc_update_existing_clauses(PredName, Arity, PredOrFunc,
        NewContext, Globals, Target, NewLang, AllProcIds, NewClauseProcId,
        Clauses0, Clauses, Overridden, !Specs) :-
    (
        Clauses0 = [],
        Clauses = [],
        Overridden = not_overridden_by_old_foreign_proc
    ;
        Clauses0 = [FirstClause0 | LaterClauses0],
        add_foreign_proc_update_existing_clauses(PredName, Arity, PredOrFunc,
            NewContext, Globals, Target, NewLang, AllProcIds, NewClauseProcId,
            LaterClauses0, LaterClauses, LaterOverridden, !Specs),
        FirstClause0 = clause(ApplProcIds0, Body, ClauseLang, ClauseContext,
            StateVarWarnings),
        (
            ClauseLang = impl_lang_mercury,
            (
                ApplProcIds0 = all_modes,
                ProcIds0 = AllProcIds
            ;
                ApplProcIds0 = selected_modes(ProcIds0)
            ),
            ( list.delete_first(ProcIds0, NewClauseProcId, ProcIds) ->
                (
                    ProcIds = [],
                    % This clause is totally overridden by the new
                    % foreign_proc, so delete it.
                    Clauses = LaterClauses
                ;
                    ProcIds = [_ | _],
                    % This clause is overridden by the new foreign_proc only
                    % in some modes, so mark it as being applicable only in the
                    % remaining modes.
                    FirstClause = clause(selected_modes(ProcIds), Body,
                        ClauseLang, ClauseContext, StateVarWarnings),
                    Clauses = [FirstClause | LaterClauses]
                )
            ;
                % This clause is not applicable to the mode of the new
                % foreign_proc, so leave it alone.
                Clauses = [FirstClause0 | LaterClauses]
            ),
            % A Mercury clause can never take precedence over a foreign_proc.
            Overridden = LaterOverridden
        ;
            ClauseLang = impl_lang_foreign(OldLang),
            (
                ApplProcIds0 = all_modes,
                unexpected($module, $pred, "all_modes")
            ;
                ApplProcIds0 = selected_modes(ProcIds0)
            ),
            ( list.delete_first(ProcIds0, NewClauseProcId, ProcIds) ->
                PreferNewForeignLang = prefer_foreign_language(Globals, Target,
                    OldLang, NewLang),
                (
                    PreferNewForeignLang = yes,
                    (
                        ProcIds = [],
                        % The language of the new foreign_proc is preferred
                        % to the language of the old foreign_proc,
                        % so we should replace the old foreign_proc.
                        Clauses = LaterClauses,
                        Overridden = LaterOverridden
                    ;
                        ProcIds = [_ | _],
                        % The language of the new foreign_proc is preferred
                        % to the language of the old foreign_proc,
                        % but the old foreign_proc is still applicable
                        % in some modes, so we keep it in those modes.
                        %
                        % XXX This should not happen.
                        FirstClause = clause(selected_modes(ProcIds), Body,
                            ClauseLang, ClauseContext, StateVarWarnings),
                        Clauses = [FirstClause | LaterClauses],
                        Overridden = LaterOverridden
                    ),
                    % Any later clause that overrides the new foreign_proc
                    % should have overridden this old foreign_proc as well.
                    expect(
                        unify(LaterOverridden,
                            not_overridden_by_old_foreign_proc),
                        $module, $pred, "inconsistent old foreign_procs")
                ;
                    PreferNewForeignLang = no,
                    % We prefer the old foreign_proc to the new one,
                    % so keep the old one and tell our caller to ignore
                    % the new one.
                    Clauses = [FirstClause0 | LaterClauses],
                    Overridden = overridden_by_old_foreign_proc,

                    % However, if the old and the new foreign_procs are
                    % in the same language, then we emit an error message
                    % as well.
                    % XXX This won't detect multiple clauses in languages
                    % that are not supported by this backend, since we filter
                    % out foreign_procs in such languages way before we get
                    % here.
                    ( OldLang = NewLang ->
                        PiecesA = [words("Error: multiple clauses for"),
                            p_or_f(PredOrFunc),
                            sym_name_and_arity(PredName / Arity),
                            words("in language"),
                            words(foreign_language_string(OldLang)),
                            suffix("."), nl],
                        PiecesB = [words("The first occurrence was here."),
                            nl],
                        MsgA = simple_msg(NewContext, [always(PiecesA)]),
                        MsgB = error_msg(yes(ClauseContext), treat_as_first, 0,
                            [always(PiecesB)]),
                        Spec = error_spec(severity_error,
                            phase_parse_tree_to_hlds, [MsgA, MsgB]),
                        !:Specs = [Spec | !.Specs]
                    ;
                        true
                    )
                )
            ;
                % This old foreign_proc is not overridden by the new one,
                % so leave it alone.
                Clauses = [FirstClause0 | LaterClauses],
                Overridden = LaterOverridden
            )
        )
    ).

%----------------------------------------------------------------------------%
:- end_module hlds.make_hlds.add_foreign_proc.
%----------------------------------------------------------------------------%
