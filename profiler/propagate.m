%-----------------------------------------------------------------------------%
% Copyright (C) 1995 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
%
% propagate.m
%
% Main author: petdr.
%
% Propagates the counts around the call_graph.
%
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module propagate.

:- interface.

:- import_module list, set, string, io.
:- import_module prof_info.

:- pred propagate__counts(list(set(string)), prof, prof, io__state, io__state).
:- mode propagate__counts(in, in, out, di, uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module float, int, map, std_util, require.
:- import_module generate_output.

% propagate_counts:
%	Propagates counts around the call_graph.  Starts from the end of the
%	list, which is the leaves of the call graph.
%	NB. Ignore the first Clique as don't need to propogate its counts.
%
propagate__counts([], Prof, Prof) --> [].
propagate__counts([ _C | Cliques], Prof0, Prof) -->
	{ prof_get_addrdeclmap(Prof0, AddrDeclMap) },
	{ prof_get_profnodemap(Prof0, ProfNodeMap0) },

	propagate_counts_2(Cliques, AddrDeclMap, ProfNodeMap0, ProfNodeMap),
	
	{ prof_set_profnodemap(ProfNodeMap, Prof0, Prof) }.


:- pred propagate_counts_2(list(set(string)), addrdecl, prof_node_map, 
					prof_node_map, io__state, io__state).
:- mode propagate_counts_2(in, in, in, out, di, uo) is det.

propagate_counts_2([], _, ProfNodeMap, ProfNodeMap) --> [].
propagate_counts_2([Clique | Cs], AddrDecl, ProfNodeMap0, ProfNodeMap) -->
	{ set__to_sorted_list(Clique, CliqueList) },

	propagate_counts_2(Cs, AddrDecl, ProfNodeMap0, ProfNodeMap1),

	% On the way up propagate the counts.
	{ build_parent_map(CliqueList, AddrDecl, ProfNodeMap1, ParentMap) },
	{ sum_counts(CliqueList, AddrDecl, ProfNodeMap1, TotalCounts) },
	{ sum_calls(ParentMap, TotalCalls) },
	{ map__to_assoc_list(ParentMap, ParentList) },
	propagate_counts_3(ParentList, TotalCounts, TotalCalls, AddrDecl, 
						ProfNodeMap1, ProfNodeMap).


:- pred propagate_counts_3(assoc_list(string, int), float, int, addrdecl, 
			prof_node_map, prof_node_map, io__state, io__state).
:- mode propagate_counts_3(in, in, in, in, in, out, di, uo) is det.

propagate_counts_3([], _, _, _, ProfNodeMap, ProfNodeMap) --> [].
propagate_counts_3([ Pred - Calls | Ps], TotalCounts, TotalCalls, AddrMap, 
						ProfNodeMap0, ProfNodeMap) -->
	{ map__lookup(AddrMap, Pred, Key),
	map__lookup(ProfNodeMap0, Key, ProfNode0),

	% Work out the number of counts to propagate.
	int__to_float(Calls, FloatCalls),
	int__to_float(TotalCalls, FloatTotalCalls),
	checked_float_divide(FloatCalls, FloatTotalCalls, Proportion),
	builtin_float_times(Proportion, TotalCounts, ToPropCount),

	% Add new counts to current propagated counts
	prof_node_get_propagated_counts(ProfNode0, PropCount0),
	builtin_float_plus(PropCount0, ToPropCount, PropCount),
	prof_node_set_propagated_counts(PropCount, ProfNode0, ProfNode),
	map__det_update(ProfNodeMap0, Key, ProfNode, ProfNodeMap1) },

	propagate_counts_3(Ps, TotalCounts, TotalCalls, AddrMap, ProfNodeMap1,
								ProfNodeMap).


% build_parent_map:
%	Builds a map which contains all the parents of a clique, and the 
%	total number of times that parent is called.  Doesn't include the 
%	clique members, and callers which never call any of the members of
%	the clique.
%
:- pred build_parent_map(list(string), addrdecl, prof_node_map, 
							map(string, int)).
:- mode build_parent_map(in, in, in, out) is det.

build_parent_map([], _AddrMap, _ProfNodeMap, _ParentMap) :-
	error("build_parent_map: empty clique list\n").
build_parent_map([C | Cs], AddrMap, ProfNodeMap, ParentMap) :-
	map__init(ParentMap0),
	build_parent_map_2([C | Cs], [C | Cs], AddrMap, ProfNodeMap, 
						ParentMap0, ParentMap).


:- pred build_parent_map_2(list(string), list(string), addrdecl, prof_node_map, 
					map(string, int), map(string, int)). 
:- mode build_parent_map_2(in, in, in, in, in, out) is det.

build_parent_map_2([], _, _, _, ParentMap, ParentMap).
build_parent_map_2([C | Cs], CliqueList, AddrMap, ProfNodeMap, ParentMap0, 	
								ParentMap) :-
	get_prof_node(C, AddrMap, ProfNodeMap, ProfNode),
	prof_node_get_parent_list(ProfNode, ParentList),
	add_to_parent_map(ParentList, CliqueList, ParentMap0, ParentMap1),
	build_parent_map_2(Cs, CliqueList, AddrMap, ProfNodeMap, ParentMap1, 
								ParentMap).


% add_to_parent_map:
% 	Adds list of parents to parent map.  Ignores clique members and
%	repeats and callers which never call current predicate.
%	Also returns the total number of times predicate is called.
%
:- pred add_to_parent_map(list(pred_info), list(string), map(string, int), 
							map(string, int)).
:- mode add_to_parent_map(in, in, in, out) is det.

add_to_parent_map([], _CliqueList, ParentMap, ParentMap).
add_to_parent_map([P | Ps], CliqueList, ParentMap0, ParentMap) :-
	pred_info_get_pred_name(P, PredName),
	pred_info_get_counts(P, Counts),
	(
		(
			list__member(PredName, CliqueList)
		;
			Counts = 0
		)
	->
		add_to_parent_map(Ps, CliqueList, ParentMap0, ParentMap)
	;	
		(
			map__search(ParentMap0, PredName, CurrCount0)
		->
			CurrCount is CurrCount0 + Counts,
			map__det_update(ParentMap0, PredName, CurrCount, 
								ParentMap1)
		;
			map__det_insert(ParentMap0, PredName, Counts, 
								ParentMap1)
		),
		add_to_parent_map(Ps, CliqueList, ParentMap1, ParentMap)
	).


% sum_counts:
%	sums the total number of counts in a clique list.
%
:- pred sum_counts(list(string), addrdecl, prof_node_map, float).
:- mode sum_counts(in, in, in, out) is det.

sum_counts([], _, _, 0.0).
sum_counts([Pred | Preds], AddrMap, ProfNodeMap, TotalCount) :-
	get_prof_node(Pred, AddrMap, ProfNodeMap, ProfNode),
	prof_node_get_initial_counts(ProfNode, InitCount),
	prof_node_get_propagated_counts(ProfNode, PropCounts),
	sum_counts(Preds, AddrMap, ProfNodeMap, TotalCount0),
	int__to_float(InitCount, InitCountFloat),
	builtin_float_plus(PropCounts, InitCountFloat, PredCount),
	builtin_float_plus(TotalCount0, PredCount, TotalCount).


% sum_calls:
%	sums the total number of calls into the clique list.
%
:- pred sum_calls(map(string, int), int).
:- mode sum_calls(in, out) is det.

sum_calls(ParentMap, TotalCalls) :-
	map__values(ParentMap, CallList),
	sum_int_list(CallList, TotalCalls).

:- pred sum_int_list(list(int), int).
:- mode sum_int_list(in, out) is det.

sum_int_list([], 0).
sum_int_list([X | Xs], Total) :-
	sum_int_list(Xs, Total0),
	Total is X + Total0.
	


%-----------------------------------------------------------------------------%
