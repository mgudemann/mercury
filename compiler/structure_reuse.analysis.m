%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2006-2008 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: structure_reuse.analysis.m.
% Main authors: nancy, wangp.
%
% Implementation of the structure reuse analysis (compile-time garbage
% collection system): each procedure is analysed to see whether some
% of the terms it manipulates become garbage thus making it possible
% to reuse that garbage straight away for creating new terms.
%
% Structure reuse is broken up into three phases: 
%   * the direct reuse analysis (structure_reuse.direct.m) 
%   * the indirect analysis (structure_reuse.indirect.m)
%   * and the generation of the optimised procedures.
% 
% The following example shows instances of direct and indirect reuse: 
%
% list.append(H1, H2, H3) :-
%   (
%       H1 => [],
%       H3 := H2
%   ;
%           % Cell H1 dies provided some condition about the
%           % structure sharing of H1 is true.  A deconstruction
%           % generating a dead cell, followed by a
%           % construction reusing that cell, is called a direct
%           % reuse. 
%       H1 => [X | Xs],
%
%           % If the condition about the structure sharing of H1
%           % is true then we can call the version of list.append 
%           % which does reuse. Calling the optimised version here leads
%           % to a new condition to be met by the headvars of any
%           % call to the resulting optimised version of append.
%           % This is an indirect reuse.
%       list.append(Xs, H2, Zs),
%
%           % Reuse the dead cell H1.  This is a direct reuse.
%       H3 <= [X | Zs]
%   ).
%
%-----------------------------------------------------------------------------%

:- module transform_hlds.ctgc.structure_reuse.analysis.
:- interface.

:- import_module analysis.
:- import_module hlds.hlds_module.
:- import_module hlds.hlds_pred.

:- import_module io. 

%-----------------------------------------------------------------------------%

    % Perform structure reuse analysis on the procedures defined in the
    % current module. 
    %
:- pred structure_reuse_analysis(module_info::in, module_info::out, 
    io::di, io::uo) is det.

    % Write all the reuse information concerning the specified predicate as
    % reuse pragmas.
    %
:- pred write_pred_reuse_info(module_info::in, pred_id::in, 
    io::di, io::uo) is det.

%-----------------------------------------------------------------------------%

:- type structure_reuse_call.
:- type structure_reuse_answer.
:- type structure_reuse_func_info.

:- instance analysis(structure_reuse_func_info, structure_reuse_call,   
    structure_reuse_answer).

:- instance call_pattern(structure_reuse_func_info, structure_reuse_call).
:- instance partial_order(structure_reuse_func_info, structure_reuse_call).
:- instance to_string(structure_reuse_call).

:- instance answer_pattern(structure_reuse_func_info, structure_reuse_answer).
:- instance partial_order(structure_reuse_func_info, structure_reuse_answer).
:- instance to_string(structure_reuse_answer).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module check_hlds.goal_path.
:- import_module hlds.passes_aux.
:- import_module hlds.pred_table.
:- import_module libs.compiler_util.
:- import_module libs.globals.
:- import_module libs.options.
:- import_module mdbcomp.prim_data.
:- import_module parse_tree.error_util.
:- import_module parse_tree.mercury_to_mercury.
:- import_module parse_tree.modules.
:- import_module parse_tree.prog_ctgc.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_out.
:- import_module parse_tree.prog_type.
:- import_module transform_hlds.ctgc.structure_reuse.direct.
:- import_module transform_hlds.ctgc.structure_reuse.domain.
:- import_module transform_hlds.ctgc.structure_reuse.indirect.
:- import_module transform_hlds.ctgc.structure_reuse.lbu.
:- import_module transform_hlds.ctgc.structure_reuse.lfu.
:- import_module transform_hlds.ctgc.structure_reuse.versions.
:- import_module transform_hlds.ctgc.structure_sharing.domain.
:- import_module transform_hlds.mmc_analysis.

:- import_module bool.
:- import_module int.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module set.
:- import_module string.
:- import_module svmap.

%-----------------------------------------------------------------------------%

structure_reuse_analysis(!ModuleInfo, !IO):- 
    globals.io_lookup_bool_option(very_verbose, VeryVerbose, !IO),

    % Load all available structure sharing information into a sharing table.
    SharingTable = load_structure_sharing_table(!.ModuleInfo),

    % Process all imported reuse information.
    globals.io_lookup_bool_option(intermodule_analysis, IntermodAnalysis, !IO),
    (
        IntermodAnalysis = yes,
        % Load structure reuse answers from the analysis registry into a reuse
        % table.  Add procedures to the module as necessary.  Look up the
        % requests made for procedures in this module by other modules.
        process_intermod_analysis_reuse(!ModuleInfo, ReuseTable0,
            ExternalRequests)
    ;
        IntermodAnalysis = no,
        % Convert imported structure reuse information into structure reuse
        % information, then load the available reuse information into a reuse
        % table.
        %
        % There is no way to request specific reuse versions of procedures
        % across module boundaries using the old intermodule optimisation
        % system.
        process_imported_reuse(!ModuleInfo),
        ReuseTable0 = load_structure_reuse_table(!.ModuleInfo),
        ExternalRequests = []
    ),

    some [!ReuseTable] (
        !:ReuseTable = ReuseTable0,

        % Pre-annotate each of the goals with "Local Forward Use" and
        % "Local Backward Use" information, and fill in all the goal_path slots
        % as well. 
        maybe_write_string(VeryVerbose, "% Annotating in use information...",
            !IO), 
        process_all_nonimported_procs(
            update_proc_io(annotate_in_use_information),
            !ModuleInfo, !IO),
        maybe_write_string(VeryVerbose, "done.\n", !IO),

        % Create copies of externally requested procedures.  This must be done
        % after the in-use annotations have been added to the procedures being
        % copied.
        list.map_foldl2(make_intermediate_reuse_proc, ExternalRequests,
            _NewPPIds, !ReuseTable, !ModuleInfo),

        % Determine information about possible direct reuses.
        maybe_write_string(VeryVerbose, "% Direct reuse...\n", !IO), 
        direct_reuse_pass(SharingTable, !ModuleInfo, !ReuseTable, !IO),
        maybe_write_string(VeryVerbose, "% Direct reuse: done.\n", !IO),
        reuse_as_table_maybe_dump(VeryVerbose, !.ModuleInfo, !.ReuseTable,
            !IO),

        % Determine information about possible indirect reuses.
        maybe_write_string(VeryVerbose, "% Indirect reuse...\n", !IO), 
        indirect_reuse_pass(SharingTable, !ModuleInfo, !ReuseTable, DepProcs0,
            InternalRequests, IntermodRequests0),
        maybe_write_string(VeryVerbose, "% Indirect reuse: done.\n", !IO),
        reuse_as_table_maybe_dump(VeryVerbose, !.ModuleInfo, !.ReuseTable,
            !IO),

        % Handle requests for "intermediate" reuse versions of procedures
        % and repeat the analyses.
        globals.io_lookup_int_option(structure_reuse_repeat, Repeats, !IO),
        handle_structure_reuse_requests(Repeats, SharingTable, InternalRequests,
            !ReuseTable, !ModuleInfo, DepProcs0, DepProcs,
            IntermodRequests0, IntermodRequests, !IO),

        % Create reuse versions of procedures.  Update goals to reuse cells and
        % call reuse versions of procedures.
        create_reuse_procedures(!ReuseTable, !ModuleInfo),

        ReuseTable = !.ReuseTable
    ),

    (
        IntermodAnalysis = no,
        % Create forwarding procedures for procedures which we thought had
        % conditional reuse when making the `.opt' file, but with further
        % information (say, from `.trans_opt' files) we decide has no reuse
        % opportunities. Otherwise other modules may contain references to
        % reuse versions of procedures which we never produce.
        create_forwarding_procedures(ReuseTable0, ReuseTable, !ModuleInfo)
    ;
        IntermodAnalysis = yes
        % We don't need to do anything here as we will have created procedures
        % corresponding to existing structure reuse answers already.
    ),

    ReuseTable = reuse_as_table(ReuseInfoMap, ReuseVersionMap),

    % Record the results of the reuse table into the HLDS.
    % This is mainly to show the reuse information in HLDS dumps as no later
    % passes need the information.
    map.foldl(save_reuse_in_module_info, ReuseInfoMap, !ModuleInfo),

    % Only write structure reuse pragmas to `.opt' files for
    % `--intermodule-optimization' not `--intermodule-analysis'.
    globals.io_lookup_bool_option(make_optimization_interface, MakeOptInt,
        !IO),
    (
        MakeOptInt = yes,
        IntermodAnalysis = no
    ->
        make_opt_int(!ModuleInfo, !IO)
    ;
        true
    ),

    % If making a `.analysis' file, record structure reuse results, analysis
    % dependencies, assumed answers and requests in the analysis framework.
    globals.io_lookup_bool_option(make_analysis_registry, MakeAnalysisRegistry,
        !IO),
    (
        MakeAnalysisRegistry = yes,
        some [!AnalysisInfo] (
            module_info_get_analysis_info(!.ModuleInfo, !:AnalysisInfo),
            CondReuseRevMap = map.reverse_map(ReuseVersionMap),
            map.foldl(
                record_structure_reuse_results(!.ModuleInfo, CondReuseRevMap),
                ReuseInfoMap, !AnalysisInfo),
            set.fold(handle_structure_reuse_dependency(!.ModuleInfo),
                DepProcs, !AnalysisInfo),
            set.fold(record_intermod_requests(!.ModuleInfo),
                IntermodRequests, !AnalysisInfo),
            module_info_set_analysis_info(!.AnalysisInfo, !ModuleInfo)
        )
    ;
        MakeAnalysisRegistry = no
    ),

    % Delete the reuse versions of procedures which turn out to have no reuse.
    % Nothing should be calling them but dead procedure elimination won't
    % remove them if they were created from exported procedures (so would be
    % exported themselves). 
    module_info_get_predicate_table(!.ModuleInfo, PredTable0),
    map.foldl(remove_useless_reuse_proc(ReuseInfoMap), ReuseVersionMap,
        PredTable0, PredTable),
    module_info_set_predicate_table(PredTable, !ModuleInfo).

%-----------------------------------------------------------------------------%

    % Create intermediate reuse versions of procedures according to the
    % requests from indirect reuse analysis.  We perform direct reuse
    % analyses on the newly created procedures, then repeat indirect reuse
    % analysis on all procedures in the module so that calls to the new
    % procedures can be made.  This may create new requests.
    %
    % XXX this is temporary only; we shouldn't be redoing so much work.
    %
:- pred handle_structure_reuse_requests(int::in, sharing_as_table::in,
    set(sr_request)::in, reuse_as_table::in, reuse_as_table::out,
    module_info::in, module_info::out,
    set(ppid_no_clobbers)::in, set(ppid_no_clobbers)::out,
    set(sr_request)::in, set(sr_request)::out, io::di, io::uo) is det.

handle_structure_reuse_requests(Repeats, SharingTable, Requests,
        !ReuseTable, !ModuleInfo, !DepProcs, !IntermodRequests, !IO) :-
    ( Repeats > 0 ->
        handle_structure_reuse_requests_2(Repeats, SharingTable, Requests,
            !ReuseTable, !ModuleInfo, !DepProcs, !IntermodRequests, !IO)
    ;
        true
    ).

:- pred handle_structure_reuse_requests_2(int::in, sharing_as_table::in,
    set(sr_request)::in, reuse_as_table::in, reuse_as_table::out,
    module_info::in, module_info::out,
    set(ppid_no_clobbers)::in, set(ppid_no_clobbers)::out,
    set(sr_request)::in, set(sr_request)::out, io::di, io::uo) is det.

handle_structure_reuse_requests_2(Repeats, SharingTable, Requests,
        !ReuseTable, !ModuleInfo, !DepProcs, !IntermodRequests, !IO) :-
    io_lookup_bool_option(very_verbose, VeryVerbose, !IO),

    % Create copies of the requested procedures.
    RequestList = set.to_sorted_list(Requests),
    list.map_foldl2(make_intermediate_reuse_proc, RequestList, NewPPIds,
        !ReuseTable, !ModuleInfo),

    % Perform direct reuse analysis on the new procedures.
    maybe_write_string(VeryVerbose, "% Repeating direct reuse...\n", !IO),
    direct_reuse_process_specific_procs(SharingTable, NewPPIds,
        !ModuleInfo, !ReuseTable, !IO),
    maybe_write_string(VeryVerbose, "% done.\n", !IO),

    % Rerun indirect reuse analysis on all procedures.
    %
    % XXX goals which already have reuse annotations don't need to be
    % reanalysed.  For old procedures (not the ones just created) we actually
    % only need to check that calls which previously had no reuse opportunity
    % might be able to call the new procedures.
    maybe_write_string(VeryVerbose, "% Repeating indirect reuse...\n", !IO),
    indirect_reuse_rerun(SharingTable, !ModuleInfo, !ReuseTable,
        NewDepProcs, NewRequests, !IntermodRequests),
    !:DepProcs = set.union(NewDepProcs, !.DepProcs),
    maybe_write_string(VeryVerbose, "% done.\n", !IO),

    ( set.empty(NewRequests) ->
        maybe_write_string(VeryVerbose,
            "% No more structure reuse requests.\n", !IO)
    ;
        maybe_write_string(VeryVerbose,
            "% Outstanding structure reuse requests exist.\n", !IO),
        handle_structure_reuse_requests(Repeats - 1, SharingTable, NewRequests,
            !ReuseTable, !ModuleInfo, !DepProcs, !IntermodRequests, !IO)
    ).

    % Create a new copy of a procedure to satisfy an intermediate reuse
    % request, i.e. some of its arguments are prevented from being reused.
    %
    % The goal of the original procedure must already be annotated with in-use
    % sets.  For the new procedure, we simply add the head variables at the
    % no-clobber argument positions to the forward-use set of each goal.
    % We also remove any existing reuse annotations on the goals.
    %
:- pred make_intermediate_reuse_proc(sr_request::in, pred_proc_id::out,
    reuse_as_table::in, reuse_as_table::out, module_info::in, module_info::out)
    is det.

make_intermediate_reuse_proc(sr_request(PPId, NoClobbers), NewPPId,
        !ReuseTable, !ModuleInfo) :-
    create_fresh_pred_proc_info_copy(PPId, NoClobbers, NewPPId, !ModuleInfo),

    module_info_pred_proc_info(!.ModuleInfo, NewPPId, PredInfo, ProcInfo0),
    proc_info_get_headvars(ProcInfo0, HeadVars),
    get_numbered_args(1, NoClobbers, HeadVars, NoClobberVars),
    add_vars_to_lfu(set.from_list(NoClobberVars), ProcInfo0, ProcInfo),
    module_info_set_pred_proc_info(NewPPId, PredInfo, ProcInfo, !ModuleInfo),

    reuse_as_table_insert_reuse_version_proc(PPId, NoClobbers, NewPPId,
        !ReuseTable).

:- pred get_numbered_args(int::in, list(int)::in, prog_vars::in,
    prog_vars::out) is det.

get_numbered_args(_, [], _, []).
get_numbered_args(_, [_ | _], [], _) :-
    unexpected(this_file, "get_numbered_args: argument list too short").
get_numbered_args(I, [N | Ns], [Var | Vars], Selected) :-
    ( I = N ->
        get_numbered_args(I + 1, Ns, Vars, Selected0),
        Selected = [Var | Selected0]
    ;
        get_numbered_args(I + 1, [N | Ns], Vars, Selected)
    ).

%-----------------------------------------------------------------------------%

:- pred create_forwarding_procedures(reuse_as_table::in, reuse_as_table::in,
    module_info::in, module_info::out) is det.

create_forwarding_procedures(InitialReuseTable, FinalReuseTable,
        !ModuleInfo) :-
    map.foldl(create_forwarding_procedures_2(FinalReuseTable),
        InitialReuseTable ^ reuse_info_map, !ModuleInfo).

:- pred create_forwarding_procedures_2(reuse_as_table::in, pred_proc_id::in,
    reuse_as_and_status::in, module_info::in, module_info::out) is det.

create_forwarding_procedures_2(FinalReuseTable, PPId,
        reuse_as_and_status(InitialReuseAs, _), !ModuleInfo) :-
    PPId = proc(PredId, _),
    module_info_pred_info(!.ModuleInfo, PredId, PredInfo),
    pred_info_get_import_status(PredInfo, ImportStatus),
    (
        reuse_as_conditional_reuses(InitialReuseAs),
        status_defined_in_this_module(ImportStatus) = yes,
        reuse_as_table_search(FinalReuseTable, PPId, FinalReuseAs_Status),
        FinalReuseAs_Status = reuse_as_and_status(FinalReuseAs, _),
        reuse_as_no_reuses(FinalReuseAs)
    ->
        NoClobbers = [],
        create_fake_reuse_procedure(PPId, NoClobbers, !ModuleInfo)
    ;
        true
    ).

%-----------------------------------------------------------------------------%

    % Process the imported reuse annotations from .opt files.
    %
:- pred process_imported_reuse(module_info::in, module_info::out) is det.

process_imported_reuse(!ModuleInfo):-
    module_info_predids(PredIds, !ModuleInfo), 
    list.foldl(process_imported_reuse_in_pred, PredIds, !ModuleInfo).

:- pred process_imported_reuse_in_pred(pred_id::in, module_info::in,
    module_info::out) is det.

process_imported_reuse_in_pred(PredId, !ModuleInfo) :- 
    some [!PredTable] (
        module_info_preds(!.ModuleInfo, !:PredTable), 
        PredInfo0 = !.PredTable ^ det_elem(PredId), 
        process_imported_reuse_in_procs(PredInfo0, PredInfo),
        svmap.det_update(PredId, PredInfo, !PredTable),
        module_info_set_preds(!.PredTable, !ModuleInfo)
    ).

:- pred process_imported_reuse_in_procs(pred_info::in, 
    pred_info::out) is det.

process_imported_reuse_in_procs(!PredInfo) :- 
    some [!ProcTable] (
        pred_info_get_procedures(!.PredInfo, !:ProcTable), 
        ProcIds = pred_info_procids(!.PredInfo), 
        list.foldl(process_imported_reuse_in_proc(!.PredInfo), 
            ProcIds, !ProcTable),
        pred_info_set_procedures(!.ProcTable, !PredInfo)
    ).

:- pred process_imported_reuse_in_proc(pred_info::in, proc_id::in, 
    proc_table::in, proc_table::out) is det.

process_imported_reuse_in_proc(PredInfo, ProcId, !ProcTable) :- 
    some [!ProcInfo] (
        !:ProcInfo = !.ProcTable ^ det_elem(ProcId), 
        (
            proc_info_get_imported_structure_reuse(!.ProcInfo, 
                ImpHeadVars, ImpTypes, ImpReuse)
        ->
            proc_info_get_headvars(!.ProcInfo, HeadVars),
            pred_info_get_arg_types(PredInfo, HeadVarTypes),
            map.from_corresponding_lists(ImpHeadVars, HeadVars, VarRenaming), 
            some [!TypeSubst] (
                !:TypeSubst = map.init, 
                (
                    type_unify_list(ImpTypes, HeadVarTypes, [], !.TypeSubst,
                        TypeSubstNew)
                ->
                    !:TypeSubst = TypeSubstNew
                ;
                    true
                ),
                rename_structure_reuse_domain(VarRenaming, !.TypeSubst,
                    ImpReuse, Reuse)
            ),
            % Optimality does not apply to `--intermodule-optimisation'
            % system, only `--intermodule-analysis'.
            proc_info_set_structure_reuse(
                structure_reuse_domain_and_status(Reuse, optimal), !ProcInfo), 
            proc_info_reset_imported_structure_reuse(!ProcInfo),
            svmap.det_update(ProcId, !.ProcInfo, !ProcTable)
        ;
            true
        )
    ).

%-----------------------------------------------------------------------------%

    % Process the intermodule imported reuse information from the analysis
    % framework.
    %
:- pred process_intermod_analysis_reuse(module_info::in, module_info::out,
    reuse_as_table::out, list(sr_request)::out) is det.

process_intermod_analysis_reuse(!ModuleInfo, ReuseTable, ExternalRequests) :-
    module_info_predids(PredIds, !ModuleInfo), 
    list.foldl3(process_intermod_analysis_reuse_pred, PredIds,
        !ModuleInfo, reuse_as_table_init, ReuseTable, [], ExternalRequests0),
    list.sort_and_remove_dups(ExternalRequests0, ExternalRequests).

:- pred process_intermod_analysis_reuse_pred(pred_id::in,
    module_info::in, module_info::out, reuse_as_table::in, reuse_as_table::out,
    list(sr_request)::in, list(sr_request)::out) is det.

process_intermod_analysis_reuse_pred(PredId, !ModuleInfo, !ReuseTable,
        !ExternalRequests) :- 
    module_info_pred_info(!.ModuleInfo, PredId, PredInfo),
    pred_info_get_import_status(PredInfo, ImportStatus),
    ProcIds = pred_info_procids(PredInfo), 
    (
        ImportStatus = status_imported(_)
    ->
        % Read in answers for imported procedures.
        list.foldl2(process_intermod_analysis_reuse_proc(PredId, PredInfo),
            ProcIds, !ModuleInfo, !ReuseTable)
    ;
        status_defined_in_this_module(ImportStatus) = yes
    ->
        % For procedures defined in this module we need to read in the answers
        % from previous passes to know which versions of procedures other
        % modules will be expecting.  We also need to read in new requests.
        list.foldl(
            process_intermod_analysis_defined_proc(!.ModuleInfo, PredId),
            ProcIds, !ExternalRequests)
    ;
        true
    ).

:- pred process_intermod_analysis_reuse_proc(pred_id::in,
    pred_info::in, proc_id::in, module_info::in, module_info::out,
    reuse_as_table::in, reuse_as_table::out) is det.

process_intermod_analysis_reuse_proc(PredId, PredInfo, ProcId,
        !ModuleInfo, !ReuseTable) :-
    PPId = proc(PredId, ProcId),
    module_info_get_analysis_info(!.ModuleInfo, AnalysisInfo),
    module_name_func_id(!.ModuleInfo, PPId, ModuleName, FuncId),
    pred_info_proc_info(PredInfo, ProcId, ProcInfo),
    lookup_results(AnalysisInfo, ModuleName, FuncId, ImportedResults),
    list.foldl2(
        process_intermod_analysis_imported_reuse_answer(PPId, PredInfo,
            ProcInfo),
        ImportedResults, !ModuleInfo, !ReuseTable).

:- pred process_intermod_analysis_imported_reuse_answer(pred_proc_id::in,
    pred_info::in, proc_info::in,
    analysis_result(structure_reuse_call, structure_reuse_answer)::in,
    module_info::in, module_info::out, reuse_as_table::in, reuse_as_table::out)
    is det.

process_intermod_analysis_imported_reuse_answer(PPId, PredInfo, ProcInfo,
        ImportedResult, !ModuleInfo, !ReuseTable) :-
    ImportedResult = analysis_result(Call, Answer, ResultStatus),
    Call = structure_reuse_call(NoClobbers),
    structure_reuse_answer_to_domain(PredInfo, ProcInfo, Answer, Domain),
    ReuseAs = from_structure_reuse_domain(Domain),
    ReuseAs_Status = reuse_as_and_status(ReuseAs, ResultStatus),
    (
        NoClobbers = [],
        % When the no-clobber list is empty we store the information with the
        % original pred_proc_id.
        reuse_as_table_set(PPId, ReuseAs_Status, !ReuseTable)
    ;
        NoClobbers = [_ | _],
        % When the no-clobber list is non-empty we need to create a new
        % procedure stub and add a mapping to from the original pred_proc_id to
        % the stub.
        create_fresh_pred_proc_info_copy(PPId, NoClobbers, NewPPId,
            !ModuleInfo),
        reuse_as_table_set(NewPPId, ReuseAs_Status, !ReuseTable),
        reuse_as_table_insert_reuse_version_proc(PPId, NoClobbers, NewPPId,
            !ReuseTable)
    ).

:- pred structure_reuse_answer_to_domain(pred_info::in,
    proc_info::in, structure_reuse_answer::in, structure_reuse_domain::out)
    is det.

structure_reuse_answer_to_domain(PredInfo, ProcInfo, Answer, Reuse) :-
    (
        Answer = structure_reuse_answer_no_reuse,
        Reuse = has_no_reuse
    ;
        Answer = structure_reuse_answer_unconditional,
        Reuse = has_only_unconditional_reuse
    ;
        Answer = structure_reuse_answer_conditional(ImpHeadVars, ImpTypes,
            ImpReuseAs),
        proc_info_get_headvars(ProcInfo, HeadVars),
        pred_info_get_arg_types(PredInfo, HeadVarTypes),
        map.from_corresponding_lists(ImpHeadVars, HeadVars, VarRenaming),
        ( type_unify_list(ImpTypes, HeadVarTypes, [], map.init, TypeSubst) ->
            ImpReuseDomain = to_structure_reuse_domain(ImpReuseAs),
            rename_structure_reuse_domain(VarRenaming, TypeSubst,
                ImpReuseDomain, Reuse)
        ;
            unexpected(this_file,
                "structure_reuse_answer_to_domain: type_unify_list failed")
        )
    ).

:- pred process_intermod_analysis_defined_proc(module_info::in, pred_id::in,
    proc_id::in, list(sr_request)::in, list(sr_request)::out) is det.

process_intermod_analysis_defined_proc(ModuleInfo, PredId, ProcId,
        !ExternalRequests) :-
    PPId = proc(PredId, ProcId),
    module_info_get_analysis_info(ModuleInfo, AnalysisInfo),
    module_name_func_id(ModuleInfo, PPId, ModuleName, FuncId),

    % Add requests corresponding to the call patterns of existing answers.
    lookup_results(AnalysisInfo, ModuleName, FuncId,
        Results : list(analysis_result(structure_reuse_call, _))),
    list.foldl(add_reuse_request_for_answer(PPId), Results, !ExternalRequests),

    % Add new requests from other modules.
    lookup_requests(AnalysisInfo, analysis_name, ModuleName, FuncId, Calls),
    list.foldl(add_reuse_request(PPId), Calls, !ExternalRequests).

:- pred add_reuse_request_for_answer(pred_proc_id::in,
    analysis_result(structure_reuse_call, structure_reuse_answer)::in,
    list(sr_request)::in, list(sr_request)::out) is det.

add_reuse_request_for_answer(PPId, Result, !ExternalRequests) :-
    add_reuse_request(PPId, Result ^ ar_call, !ExternalRequests).

:- pred add_reuse_request(pred_proc_id::in, structure_reuse_call::in,
    list(sr_request)::in, list(sr_request)::out) is det.

add_reuse_request(PPId, structure_reuse_call(NoClobbers), !Requests) :-
    (
        NoClobbers = []
        % We don't need to add these as explicit requests, and in fact it's
        % better if we don't.  The analysis is already designed to analyse for
        % this case by default and create the reuse procedures if necessary.
    ;
        NoClobbers = [_ | _],
        !:Requests = [sr_request(PPId, NoClobbers) | !.Requests]
    ).

%-----------------------------------------------------------------------------%

:- pred save_reuse_in_module_info(pred_proc_id::in, reuse_as_and_status::in,
    module_info::in, module_info::out) is det.

save_reuse_in_module_info(PPId, ReuseAs_Status, !ModuleInfo) :- 
    ReuseAs_Status = reuse_as_and_status(ReuseAs, Status),
    ReuseDomain = to_structure_reuse_domain(ReuseAs),
    Domain_Status = structure_reuse_domain_and_status(ReuseDomain, Status),

    module_info_pred_proc_info(!.ModuleInfo, PPId, PredInfo, ProcInfo0),
    proc_info_set_structure_reuse(Domain_Status, ProcInfo0, ProcInfo),
    module_info_set_pred_proc_info(PPId, PredInfo, ProcInfo, !ModuleInfo).

:- pred annotate_in_use_information(pred_id::in, proc_id::in,
    module_info::in, proc_info::in, proc_info::out, io::di, io::uo) is det.

annotate_in_use_information(_PredId, _ProcId, ModuleInfo, !ProcInfo, !IO) :- 
    forward_use_information(!ProcInfo), 
    backward_use_information(ModuleInfo, !ProcInfo),
    fill_goal_path_slots(ModuleInfo, !ProcInfo).

%-----------------------------------------------------------------------------%
%
% Code for writing out optimization interfaces
%

:- pred make_opt_int(module_info::in, module_info::out, io::di, io::uo) is det.

make_opt_int(!ModuleInfo, !IO) :-
    module_info_get_name(!.ModuleInfo, ModuleName),
    module_name_to_file_name(ModuleName, ".opt.tmp", no, OptFileName, !IO),
    globals.io_lookup_bool_option(verbose, Verbose, !IO),
    maybe_write_string(Verbose, "% Appending structure_reuse pragmas to ",
        !IO),
    maybe_write_string(Verbose, add_quotes(OptFileName), !IO),
    maybe_write_string(Verbose, "...", !IO),
    maybe_flush_output(Verbose, !IO),
    io.open_append(OptFileName, OptFileRes, !IO),
    (
        OptFileRes = ok(OptFile),
        io.set_output_stream(OptFile, OldStream, !IO),
        module_info_predids(PredIds, !ModuleInfo),   
        list.foldl(write_pred_reuse_info(!.ModuleInfo), PredIds, !IO),
        io.set_output_stream(OldStream, _, !IO),
        io.close_output(OptFile, !IO),
        maybe_write_string(Verbose, " done.\n", !IO)
    ;
        OptFileRes = error(IOError),
        maybe_write_string(Verbose, " failed!\n", !IO),
        io.error_message(IOError, IOErrorMessage),
        io.write_strings(["Error opening file `",
            OptFileName, "' for output: ", IOErrorMessage], !IO),
        io.set_exit_status(1, !IO)
    ).  

%-----------------------------------------------------------------------------%
%
% Code for writing out structure_reuse pragmas
%

write_pred_reuse_info(ModuleInfo, PredId, !IO) :-
    module_info_pred_info(ModuleInfo, PredId, PredInfo),
    PredName = pred_info_name(PredInfo),
    ProcIds = pred_info_procids(PredInfo),
    PredOrFunc = pred_info_is_pred_or_func(PredInfo),
    ModuleName = pred_info_module(PredInfo),
    pred_info_get_procedures(PredInfo, ProcTable),
    pred_info_get_context(PredInfo, Context),
    SymName = qualified(ModuleName, PredName),
    pred_info_get_typevarset(PredInfo, TypeVarSet),
    list.foldl(write_proc_reuse_info(ModuleInfo, PredId, PredInfo, ProcTable,
        PredOrFunc, SymName, Context, TypeVarSet), ProcIds, !IO).

:- pred write_proc_reuse_info(module_info::in, pred_id::in, pred_info::in,
    proc_table::in, pred_or_func::in, sym_name::in, prog_context::in,
    tvarset::in, proc_id::in, io::di, io::uo) is det.

write_proc_reuse_info(ModuleInfo, PredId, PredInfo, ProcTable, PredOrFunc,
        SymName, Context, TypeVarSet, ProcId, !IO) :-
    should_write_reuse_info(ModuleInfo, PredId, ProcId, PredInfo,
        disallow_type_spec_preds, ShouldWrite),
    (
        ShouldWrite = yes,
        map.lookup(ProcTable, ProcId, ProcInfo),
        proc_info_get_structure_reuse(ProcInfo, MaybeStructureReuseDomain),
        (
            MaybeStructureReuseDomain = yes(
                structure_reuse_domain_and_status(Reuse, _Status)),
            proc_info_declared_argmodes(ProcInfo, Modes),
            proc_info_get_varset(ProcInfo, VarSet),
            proc_info_get_headvars(ProcInfo, HeadVars),
            proc_info_get_vartypes(ProcInfo, VarTypes),
            list.map(map.lookup(VarTypes), HeadVars, HeadVarTypes),
                MaybeReuse = yes(Reuse),
            write_pragma_structure_reuse_info(PredOrFunc, SymName, Modes,
                Context, HeadVars, yes(VarSet), HeadVarTypes, yes(TypeVarSet),
                MaybeReuse, !IO)
        ;
            MaybeStructureReuseDomain = no
        )
    ;
        ShouldWrite = no
    ).

%-----------------------------------------------------------------------------%
%
% Types and instances for the intermodule analysis framework
%

:- type structure_reuse_call
    --->    structure_reuse_call(no_clobber_args).

:- type structure_reuse_answer
    --->    structure_reuse_answer_no_reuse
    ;       structure_reuse_answer_unconditional
    ;       structure_reuse_answer_conditional(
                prog_vars,
                list(mer_type),
                reuse_as
            ).

:- type structure_reuse_func_info
    --->    structure_reuse_func_info(
                module_info,
                proc_info
            ).

:- func analysis_name = string.

analysis_name = "structure_reuse".

:- instance analysis(structure_reuse_func_info, structure_reuse_call,
    structure_reuse_answer) where
[
    analysis_name(_, _) = analysis_name,
    analysis_version_number(_, _) = 2,
    preferred_fixpoint_type(_, _) = greatest_fixpoint,
    bottom(_, _) = structure_reuse_answer_no_reuse,
    ( top(_, _) = _ :-
        % We have no representation for "all possible conditions".
        unexpected(this_file, "top/2 called")
    ),
    ( get_func_info(ModuleInfo, ModuleName, FuncId, _, _, FuncInfo) :-
        func_id_to_ppid(ModuleInfo, ModuleName, FuncId, PPId),
        module_info_proc_info(ModuleInfo, PPId, ProcInfo),
        FuncInfo = structure_reuse_func_info(ModuleInfo, ProcInfo)
    )
].

:- instance call_pattern(structure_reuse_func_info, structure_reuse_call)
    where [].

:- instance partial_order(structure_reuse_func_info, structure_reuse_call)
        where [
    (more_precise_than(_, Call1, Call2) :-
        Call1 = structure_reuse_call(Args1),
        Call2 = structure_reuse_call(Args2),
        set.subset(sorted_list_to_set(Args2), sorted_list_to_set(Args1))
    ),
    equivalent(_, Call, Call)
].

:- instance to_string(structure_reuse_call) where [
    ( to_string(structure_reuse_call(List)) = String :-
        Strs = list.map(string.from_int, List),
        String = string.join_list(" ", Strs)
    ),
    ( from_string(String) = structure_reuse_call(List) :-
        Strs = string.words(String),
        List = list.map(string.det_to_int, Strs)
    )
].

:- instance answer_pattern(structure_reuse_func_info, structure_reuse_answer)
    where [].

:- instance partial_order(structure_reuse_func_info, structure_reuse_answer)
        where [

    % We deliberately have `conditional' reuse incomparable with
    % `unconditional' reuse.  If they were comparable, a caller using an
    % `conditional' answer would would only be marked `suboptimal' if that
    % answer changes to `unconditional'.  Since we don't honour the old
    % `conditional' answer by generating that version of the procedure, there
    % would be a linking error if the caller is not updated to call the
    % unconditional version.

    (more_precise_than(FuncInfo, Answer1, Answer2) :-
        (
            Answer1 = structure_reuse_answer_conditional(_, _, _),
            Answer2 = structure_reuse_answer_no_reuse
        ;
            Answer1 = structure_reuse_answer_unconditional,
            Answer2 = structure_reuse_answer_no_reuse
        ;
            Answer1 = structure_reuse_answer_conditional(_, _, ReuseAs1),
            Answer2 = structure_reuse_answer_conditional(_, _, ReuseAs2),
            % XXX can we implement this more efficiently?
            FuncInfo = structure_reuse_func_info(ModuleInfo, ProcInfo),
            reuse_as_subsumed_by(ModuleInfo, ProcInfo, ReuseAs1, ReuseAs2),
            not reuse_as_subsumed_by(ModuleInfo, ProcInfo, ReuseAs2, ReuseAs1)
        )
    ),

    (equivalent(FuncInfo, Answer1, Answer2) :-
        (
            Answer1 = Answer2
        ;
            Answer1 = structure_reuse_answer_conditional(_, _, ReuseAs1),
            Answer2 = structure_reuse_answer_conditional(_, _, ReuseAs2),
            % XXX can we implement this more efficiently?
            FuncInfo = structure_reuse_func_info(ModuleInfo, ProcInfo),
            reuse_as_subsumed_by(ModuleInfo, ProcInfo, ReuseAs2, ReuseAs1),
            reuse_as_subsumed_by(ModuleInfo, ProcInfo, ReuseAs1, ReuseAs2)
        )
    )
].

:- instance to_string(structure_reuse_answer) where [
    func(to_string/1) is reuse_answer_to_string,
    func(from_string/1) is reuse_answer_from_string
].

:- func reuse_answer_to_string(structure_reuse_answer) = string.

reuse_answer_to_string(Answer) = String :-
    (
        Answer = structure_reuse_answer_no_reuse,
        String = "no_reuse"
    ;
        Answer = structure_reuse_answer_unconditional,
        String = "uncond"
    ;
        Answer = structure_reuse_answer_conditional(HeadVars, Types, ReuseAs),
        ReuseDomain = to_structure_reuse_domain(ReuseAs),
        String = string({HeadVars, Types, ReuseDomain})
    ).

:- func reuse_answer_from_string(string::in) =
    (structure_reuse_answer::out) is det.

reuse_answer_from_string(String) = Answer :-
    ( String = "no_reuse" ->
        Answer = structure_reuse_answer_no_reuse
    ; String = "uncond" ->
        Answer = structure_reuse_answer_unconditional
    ;
        % XXX this is ugly.  Later we should move to writing call and answer
        % patterns in analysis files as terms rather than strings which will
        % clean this up.
        StringStop = String ++ ".",
        io.read_from_string("", StringStop, string.length(StringStop), Res,
            posn(0, 0, 0), _Posn),
        (
            Res = ok({HeadVars, Types, ReuseDomain}),
            ReuseAs = from_structure_reuse_domain(ReuseDomain),
            Answer = structure_reuse_answer_conditional(HeadVars, Types,
                ReuseAs)
        ;
            ( Res = eof
            ; Res = error(_, _)
            ),
            unexpected(this_file, "reuse_answer_from_string: " ++ String)
        )
    ).

%-----------------------------------------------------------------------------%
%
% Additional predicates used for intermodule analysis
%

:- pred record_structure_reuse_results(module_info::in,
    map(pred_proc_id, set(ppid_no_clobbers))::in, pred_proc_id::in,
    reuse_as_and_status::in, analysis_info::in, analysis_info::out) is det.

record_structure_reuse_results(ModuleInfo, CondReuseReverseMap,
        PPId, ReuseAs_Status, !AnalysisInfo) :-
    ( map.search(CondReuseReverseMap, PPId, Set) ->
        % PPId is a conditional reuse procedure created from another procedure.
        % We need to record the result using the name of the original
        % procedure.
        ( set.singleton_set(Set, Elem) ->
            Elem = ppid_no_clobbers(RecordPPId, NoClobbers)
        ;
            unexpected(this_file,
                "record_structure_reuse_results: non-singleton set")
        )
    ;
        RecordPPId = PPId,
        NoClobbers = []
    ),
    record_structure_reuse_results_2(ModuleInfo, RecordPPId, NoClobbers,
        ReuseAs_Status, !AnalysisInfo).

:- pred record_structure_reuse_results_2(module_info::in, pred_proc_id::in,
    no_clobber_args::in, reuse_as_and_status::in,
    analysis_info::in, analysis_info::out) is det.

record_structure_reuse_results_2(ModuleInfo, PPId, NoClobbers, ReuseAs_Status,
        !AnalysisInfo) :-
    PPId = proc(PredId, ProcId),
    ReuseAs_Status = reuse_as_and_status(ReuseAs, Status),

    module_info_pred_info(ModuleInfo, PredId, PredInfo),
    should_write_reuse_info(ModuleInfo, PredId, ProcId, PredInfo,
        allow_type_spec_preds, ShouldWrite),
    (
        ShouldWrite = yes,
        ( reuse_as_no_reuses(ReuseAs) ->
            Answer = structure_reuse_answer_no_reuse
        ; reuse_as_all_unconditional_reuses(ReuseAs) ->
            Answer = structure_reuse_answer_unconditional
        ; reuse_as_conditional_reuses(ReuseAs) ->
            module_info_pred_proc_info(ModuleInfo, PPId, _PredInfo,
                ProcInfo),
            proc_info_get_headvars(ProcInfo, HeadVars),
            proc_info_get_vartypes(ProcInfo, VarTypes),
            map.apply_to_list(HeadVars, VarTypes, HeadVarTypes),
            Answer = structure_reuse_answer_conditional(HeadVars,
                HeadVarTypes, ReuseAs)
        ;
            unexpected(this_file, "record_structure_reuse_results")
        ),
        module_name_func_id(ModuleInfo, PPId, ModuleName, FuncId),
        record_result(ModuleName, FuncId, structure_reuse_call(NoClobbers),
            Answer, Status, !AnalysisInfo)
    ;
        ShouldWrite = no
    ).

:- pred handle_structure_reuse_dependency(module_info::in,
    ppid_no_clobbers::in, analysis_info::in, analysis_info::out) is det.

handle_structure_reuse_dependency(ModuleInfo,
        ppid_no_clobbers(DepPPId, NoClobbers), !AnalysisInfo) :-
    % Record that we depend on the result for the called procedure.
    module_info_get_name(ModuleInfo, ThisModuleName),
    module_name_func_id(ModuleInfo, DepPPId, DepModuleName, DepFuncId),
    Call = structure_reuse_call(NoClobbers),
    record_dependency(ThisModuleName, analysis_name, DepModuleName, DepFuncId,
        Call, !AnalysisInfo),

    % If the called procedure didn't have an answer in the analysis registry,
    % record the assumed answer for it so that when it does get
    % analysed, it will have something to compare against.
    module_info_proc_info(ModuleInfo, DepPPId, ProcInfo),
    FuncInfo = structure_reuse_func_info(ModuleInfo, ProcInfo),
    lookup_matching_results(!.AnalysisInfo, DepModuleName, DepFuncId, FuncInfo,
        Call, AnyResults : list(analysis_result(structure_reuse_call,
            structure_reuse_answer))),
    (
        AnyResults = [],
        Answer = bottom(FuncInfo, Call) : structure_reuse_answer,
        % We assume an unknown answer is `optimal' otherwise we would not be
        % able to get mutually recursive procedures out of the `suboptimal'
        % state.
        record_result(DepModuleName, DepFuncId, Call, Answer, optimal,
            !AnalysisInfo),
        % Record a request as well.
        record_request(analysis_name, DepModuleName, DepFuncId, Call,
            !AnalysisInfo)
    ;
        AnyResults = [_ | _]
    ).

:- pred record_intermod_requests(module_info::in, sr_request::in,
    analysis_info::in, analysis_info::out) is det.

record_intermod_requests(ModuleInfo, sr_request(PPId, NoClobbers),
        !AnalysisInfo) :-
    module_name_func_id(ModuleInfo, PPId, ModuleName, FuncId),
    record_request(analysis_name, ModuleName, FuncId,
        structure_reuse_call(NoClobbers), !AnalysisInfo).

%-----------------------------------------------------------------------------%

:- type allow_type_spec_preds
    --->    allow_type_spec_preds
    ;       disallow_type_spec_preds.

:- pred should_write_reuse_info(module_info::in, pred_id::in, proc_id::in,
    pred_info::in, allow_type_spec_preds::in, bool::out) is det.

should_write_reuse_info(ModuleInfo, PredId, ProcId, PredInfo,
        AllowTypeSpecPreds, ShouldWrite) :-
    (
        procedure_is_exported(ModuleInfo, PredInfo, ProcId),
        \+ is_unify_or_compare_pred(PredInfo),

        % Don't write out info for reuse versions of procedures.
        pred_info_get_origin(PredInfo, PredOrigin),
        PredOrigin \= origin_transformed(transform_structure_reuse, _, _),

        (
            AllowTypeSpecPreds = allow_type_spec_preds
        ;
            AllowTypeSpecPreds = disallow_type_spec_preds,
            % XXX These should be allowed, but the predicate declaration for
            % the specialized predicate is not produced before the structure
            % reuse pragmas are read in, resulting in an undefined predicate
            % error.
            module_info_get_type_spec_info(ModuleInfo, TypeSpecInfo),
            TypeSpecInfo = type_spec_info(_, TypeSpecForcePreds, _, _),
            \+ set.member(PredId, TypeSpecForcePreds)
        )
    ->
        ShouldWrite = yes
    ;
        ShouldWrite = no
    ).

%-----------------------------------------------------------------------------%

:- pred remove_useless_reuse_proc(map(pred_proc_id, reuse_as_and_status)::in,
    ppid_no_clobbers::in, pred_proc_id::in,
    predicate_table::in, predicate_table::out) is det.

remove_useless_reuse_proc(ReuseAsMap, _, PPId, !PredTable) :-
    map.lookup(ReuseAsMap, PPId, ReuseAs_Status),
    ReuseAs_Status = reuse_as_and_status(ReuseAs, _),
    % XXX perhaps we can also remove reuse procedures with only unconditional
    % reuse?  Such a procedure should be the same as the "non-reuse" procedure
    % (which also implements any unconditional reuse).
    ( reuse_as_no_reuses(ReuseAs) ->
        PPId = proc(PredId, _),
        % We can remove the whole predicate because we never generate
        % multi-moded reuse versions of predicates.
        predicate_table_remove_predicate(PredId, !PredTable)
    ;
        true
    ).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "structure_reuse.analysis.m".

%-----------------------------------------------------------------------------%
:- end_module transform_hlds.ctgc.structure_reuse.analysis.
%-----------------------------------------------------------------------------%
