%-----------------------------------------------------------------------------%
% Copyright (C) 2000 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% Definitions of data structures for representing run-time type information
% within the compiler. When output by rtti_out.m, values of most these types
% will correspond to the types defined in runtime/mercury_type_info.h;
% the documentation of those types can be found there.
% The code to generate the structures is in type_ctor_info.m.
% See also pseudo_type_info.m.
%
% This module is independent of whether we are compiling to LLDS or MLDS.
% It is used as an intermediate data structure that we generate from the
% HLDS, and which we can then convert to either LLDS or MLDS.
% The LLDS actually incorporates this data structure unchanged.
%
% Authors: zs, fjh.

%-----------------------------------------------------------------------------%

:- module rtti.

:- interface.

:- import_module hlds_module, hlds_pred.
:- import_module prog_data, pseudo_type_info.

:- import_module bool, list, std_util.

	% For a given du type and a primary tag value, this says where,
	% if anywhere, the secondary tag is.
:- type sectag_locn
	--->	sectag_none
	;	sectag_local
	;	sectag_remote.

	% For a given du family type, this says whether the user has defined
	% their own unification predicate.
:- type equality_axioms
	--->	standard
	;	user_defined.

	% For a notag or equiv type, this says whether the target type
	% contains variables or not.
:- type equiv_type_inst
	--->	equiv_type_is_ground
	;	equiv_type_is_not_ground.

	% The compiler is concerned with the type constructor representations
	% of only the types it generates RTTI information for; it need not and
	% does not know about the type_ctor_reps of types which have
	% hand-defined RTTI.
:- type type_ctor_rep
	--->	enum(equality_axioms)
	;	du(equality_axioms)
	;	notag(equality_axioms, equiv_type_inst)
	;	equiv(equiv_type_inst)
	;	unknown.

	% Different kinds of types have different type_layout information
	% generated for them, and some have no type_layout info at all.
	% This type represents values that will be put into the type_layout
	% field of a MR_TypeCtorInfo.
:- type type_ctor_layout_info
	--->	enum_layout(
			rtti_name
		)
	;	notag_layout(
			rtti_name
		)
	;	du_layout(
			rtti_name
		)
	;	equiv_layout(
			rtti_data	% a pseudo_type_info rtti_data
		)
	;	no_layout.

	% Different kinds of types have different type_functors information
	% generated for them, and some have no type_functors info at all.
	% This type represents values that will be put into the type_functors
	% field of a MR_TypeCtorInfo.
:- type type_ctor_functors_info
	--->	enum_functors(
			rtti_name
		)
	;	notag_functors(
			rtti_name
		)
	;	du_functors(
			rtti_name
		)
	;	no_functors.

	% This type corresponds to the C type MR_DuExistLocn.
:- type exist_typeinfo_locn
	--->	plain_typeinfo(
			int			% The typeinfo is stored
						% directly in the cell, at this
						% offset.
		)
	;	typeinfo_in_tci(
			int,			% The typeinfo is stored
						% indirectly in the typeclass
						% info stored at this offset
						% in the cell.
			int			% To find the typeinfo inside
						% the typeclass info structure,
						% give this integer to the
						% MR_typeclass_info_type_info
						% macro.
		).

	% This type corresponds to the MR_DuPtagTypeLayout C type.
:- type du_ptag_layout
	--->	du_ptag_layout(
			int,			% number of function symbols
						% sharing this primary tag
			sectag_locn,
			rtti_name		% a vector of size num_sharers;
						% element N points to the
						% functor descriptor for the
						% functor with secondary tag S;
						% if sectag_locn is none, S=0
		).

	% Values of this type uniquely identify a type in the program.
:- type rtti_type_id
	--->	rtti_type_id(
			module_name,		% module name
			string,			% type ctor's name
			arity			% type ctor's arity
		).

	% Global data generated by the compiler. Usually readonly,
	% with one exception: data containing code addresses must
	% be initialized at runtime in grades that don't support static
	% code initializers.
:- type rtti_data
	--->	exist_locns(
			rtti_type_id,		% identifies the type
			int,			% identifies functor in type

			% The remaining argument of this function symbol
			% corresponds to an array of MR_ExistTypeInfoLocns.

			list(exist_typeinfo_locn)
		)
	;	exist_info(
			rtti_type_id,		% identifies the type
			int,			% identifies functor in type

			% The remaining arguments of this function symbol
			% correspond to the MR_DuExistInfo C type.

			int,			% number of plain typeinfos
			int,			% number of typeinfos in tcis
			int,			% number of tcis
			rtti_name		% table of typeinfo locations
		)
	;	field_names(
			rtti_type_id,		% identifies the type
			int,			% identifies functor in type

			list(maybe(string))	% gives the field names
		)
	;	field_types(
			rtti_type_id,		% identifies the type
			int,			% identifies functor in type

			list(rtti_data)		% gives the field types
						% (as pseudo_type_info
						% rtti_data)
		)
	;	enum_functor_desc(
			rtti_type_id,		% identifies the type

			% The remaining arguments of this function symbol
			% correspond one-to-one to the fields of
			% MR_EnumFunctorDesc.

			string,			% functor name
			int			% ordinal number of functor
						% (also its value)
		)
	;	notag_functor_desc(
			rtti_type_id,		% identifies the type

			% The remaining arguments of this function symbol
			% correspond one-to-one to the fields of
			% the MR_NotagFunctorDesc C type.

			string,			% functor name
			rtti_data		% pseudo typeinfo of argument
						% (as a pseudo_type_info
						% rtti_data)
		)
	;	du_functor_desc(
			rtti_type_id,		% identifies the type

			% The remaining arguments of this function symbol
			% correspond one-to-one to the fields of
			% the MR_DuFunctorDesc C type.

			string,			% functor name
			int,			% functor primary tag
			int,			% functor secondary tag
			sectag_locn,
			int,			% ordinal number of functor
						% in type definition
			arity,			% the functor's visible arity
			int,			% a bit vector of size at most
						% contains_var_bit_vector_size
						% which contains a 1 bit in the
						% position given by 1 << N if
						% the type of argument N
						% contains variables (assuming
						% that arguments are numbered
						% from zero)
			rtti_name,		% a vector of length arity
						% containing the pseudo
						% typeinfos of the arguments
						% (a field_types rtti_name)
			maybe(rtti_name),	% possibly a vector of length
						% arity containing the names
						% of the arguments, if any
						% (a field_names rtti_name)
			maybe(rtti_name)	% information about the
						% existentially quantified
						% type variables, if any
						% (an exist_info rtti_name)
		)
	;	enum_name_ordered_table(
			rtti_type_id,		% identifies the type

			% The remaining argument of this function symbol
			% corresponds to the functors_enum alternative of
			% the MR_TypeFunctors C type.

			list(rtti_name)
		)	
	;	enum_value_ordered_table(
			rtti_type_id,		% identifies the type

			% The remaining argument of this function symbol
			% corresponds to the MR_EnumTypeLayout C type.

			list(rtti_name)
		)	
	;	du_name_ordered_table(
			rtti_type_id,		% identifies the type

			% The remaining argument of this function symbol
			% corresponds to the functors_du alternative of
			% the MR_TypeFunctors C type.

			list(rtti_name)
		)	
	;	du_stag_ordered_table(
			rtti_type_id,		% identifies the type
			int,			% primary tag value

			% The remaining argument of this function symbol
			% corresponds to the MR_sectag_alternatives field
			% of the MR_DuPtagTypeLayout C type.

			list(rtti_name)
		)	
	;	du_ptag_ordered_table(
			rtti_type_id,		% identifies the type

			% The remaining argument of this function symbol
			% corresponds to the elements of the MR_DuTypeLayout
			% C type.

			list(du_ptag_layout)
		)	
	;	type_ctor_info(
			% The arguments of this function symbol correspond
			% one-to-one to the fields of the MR_TypeCtorInfo
			% C type.

			rtti_type_id,		% identifies the type ctor
			maybe(rtti_proc_label),	% unify
			maybe(rtti_proc_label),	% compare
			type_ctor_rep,
			maybe(rtti_proc_label),	% solver
			maybe(rtti_proc_label),	% init
			int,			% RTTI version number
			int,			% num of ptags used if ctor_rep
						% is DU or DUUSEREQ
			int,			% number of functors in type
			type_ctor_functors_info,% the functor layout
			type_ctor_layout_info,	% the layout table
			maybe(rtti_name),	% the type's hash cons table
			maybe(rtti_proc_label)	% prettyprinter
		)
	;	pseudo_type_info(pseudo_type_info)
	.

:- type rtti_name
	--->	exist_locns(int)		% functor ordinal
	;	exist_info(int)			% functor ordinal
	;	field_names(int)		% functor ordinal
	;	field_types(int)		% functor ordinal
	;	enum_functor_desc(int)		% functor ordinal
	;	notag_functor_desc
	;	du_functor_desc(int)		% functor ordinal
	;	enum_name_ordered_table
	;	enum_value_ordered_table
	;	du_name_ordered_table
	;	du_stag_ordered_table(int)	% primary tag
	;	du_ptag_ordered_table
	;	type_ctor_info
	;	pseudo_type_info(pseudo_type_info)
	;	type_hashcons_pointer.

	% The rtti_proc_label type holds all the information about a procedure
	% that we need to compute the entry label for that procedure
	% in the target language (the llds__code_addr or mlds__code_addr).
:- type rtti_proc_label
	--->	rtti_proc_label(
			pred_or_func		::	pred_or_func,
			this_module		::	module_name,
			pred_module		::	module_name,
			pred_name		::	string,
			arity			::	arity,
			arg_types		::	list(type),
			pred_id			::	pred_id,
			proc_id			::	proc_id,
			%
			% The following booleans hold values computed from the
			% pred_info, using procedures
			%	pred_info_is_imported/1,
			%	pred_info_is_pseudo_imported/1,
			%	procedure_is_exported/2, and
			%	pred_info_is_compiler_generated/1
			% respectively.
			% We store booleans here, rather than storing the
			% pred_info, to avoid retaining a reference to the
			% parts of the pred_info that we aren't interested in,
			% so that those parts can be garbage collected.
			% We use booleans rather than an import_status
			% so that we can continue to use the above-mentioned
			% abstract interfaces rather than hard-coding tests
			% on the import_status.
			%
			is_imported			::	bool,
			is_pseudo_imported		::	bool,
			is_exported			::	bool,
			is_special_pred_instance	::	bool
		).

	% Construct an rtti_proc_label for a given procedure.

:- func rtti__make_proc_label(module_info, pred_id, proc_id) = rtti_proc_label.

	% Return the C variable name of the RTTI data structure identified
	% by the input arguments.
	% XXX this should be in rtti_out.m

:- pred rtti__addr_to_string(rtti_type_id::in, rtti_name::in, string::out)
	is det.

	% Return the C representation of a secondary tag location.
	% XXX this should be in rtti_out.m

:- pred rtti__sectag_locn_to_string(sectag_locn::in, string::out) is det.

	% Return the C representation of a type_ctor_rep value.
	% XXX this should be in rtti_out.m

:- pred rtti__type_ctor_rep_to_string(type_ctor_rep::in, string::out) is det.

:- implementation.

:- import_module code_util.	% for code_util__compiler_defined
:- import_module llds_out.	% for name_mangle and sym_name_mangle
:- import_module hlds_data, type_util.

:- import_module string, require.

rtti__make_proc_label(ModuleInfo, PredId, ProcId) = ProcLabel :-
	module_info_name(ModuleInfo, ThisModule),
	module_info_pred_info(ModuleInfo, PredId, PredInfo),
	pred_info_get_is_pred_or_func(PredInfo, PredOrFunc),
	pred_info_module(PredInfo, PredModule),
	pred_info_name(PredInfo, PredName),
	pred_info_arity(PredInfo, Arity),
	pred_info_arg_types(PredInfo, ArgTypes),
	IsImported = (pred_info_is_imported(PredInfo) -> yes ; no),
	IsPseudoImp = (pred_info_is_pseudo_imported(PredInfo) -> yes ; no),
	IsExported = (procedure_is_exported(PredInfo, ProcId) -> yes ; no),
	IsSpecialPredInstance =
		(code_util__compiler_generated(PredInfo) -> yes ; no),
	ProcLabel = rtti_proc_label(PredOrFunc, ThisModule, PredModule,
		PredName, Arity, ArgTypes, PredId, ProcId,
		IsImported, IsPseudoImp, IsExported, IsSpecialPredInstance).

rtti__addr_to_string(RttiTypeId, RttiName, Str) :-
	rtti__mangle_rtti_type_id(RttiTypeId, ModuleName, TypeName, A_str),
	(
		RttiName = exist_locns(Ordinal),
		string__int_to_string(Ordinal, O_str),
		string__append_list([ModuleName, "__exist_locns_",
			TypeName, "_", A_str, "_", O_str], Str)
	;
		RttiName = exist_info(Ordinal),
		string__int_to_string(Ordinal, O_str),
		string__append_list([ModuleName, "__exist_info_",
			TypeName, "_", A_str, "_", O_str], Str)
	;
		RttiName = field_names(Ordinal),
		string__int_to_string(Ordinal, O_str),
		string__append_list([ModuleName, "__field_names_",
			TypeName, "_", A_str, "_", O_str], Str)
	;
		RttiName = field_types(Ordinal),
		string__int_to_string(Ordinal, O_str),
		string__append_list([ModuleName, "__field_types_",
			TypeName, "_", A_str, "_", O_str], Str)
	;
		RttiName = enum_functor_desc(Ordinal),
		string__int_to_string(Ordinal, O_str),
		string__append_list([ModuleName, "__enum_functor_desc_",
			TypeName, "_", A_str, "_", O_str], Str)
	;
		RttiName = notag_functor_desc,
		string__append_list([ModuleName, "__notag_functor_desc_",
			TypeName, "_", A_str], Str)
	;
		RttiName = du_functor_desc(Ordinal),
		string__int_to_string(Ordinal, O_str),
		string__append_list([ModuleName, "__du_functor_desc_",
			TypeName, "_", A_str, "_", O_str], Str)
	;
		RttiName = enum_name_ordered_table,
		string__append_list([ModuleName, "__enum_name_ordered_",
			TypeName, "_", A_str], Str)
	;
		RttiName = enum_value_ordered_table,
		string__append_list([ModuleName, "__enum_value_ordered_",
			TypeName, "_", A_str], Str)
	;
		RttiName = du_name_ordered_table,
		string__append_list([ModuleName, "__du_name_ordered_",
			TypeName, "_", A_str], Str)
	;
		RttiName = du_stag_ordered_table(Ptag),
		string__int_to_string(Ptag, P_str),
		string__append_list([ModuleName, "__du_stag_ordered_",
			TypeName, "_", A_str, "_", P_str], Str)
	;
		RttiName = du_ptag_ordered_table,
		string__append_list([ModuleName, "__du_ptag_ordered_",
			TypeName, "_", A_str], Str)
	;
		RttiName = type_ctor_info,
		string__append_list([ModuleName, "__type_ctor_info_",
			TypeName, "_", A_str], Str)
	;
		RttiName = pseudo_type_info(PseudoTypeInfo),
		rtti__pseudo_type_info_to_string(PseudoTypeInfo, Str)
	;
		RttiName = type_hashcons_pointer,
		string__append_list([ModuleName, "__hashcons_ptr_",
			TypeName, "_", A_str], Str)
	).

:- pred rtti__mangle_rtti_type_id(rtti_type_id, string, string, string).
:- mode rtti__mangle_rtti_type_id(in, out, out, out) is det.

rtti__mangle_rtti_type_id(RttiTypeId, ModuleName, TypeName, A_str) :-
	RttiTypeId = rtti_type_id(ModuleName0, TypeName0, TypeArity),
	llds_out__sym_name_mangle(ModuleName0, ModuleName),
	llds_out__name_mangle(TypeName0, TypeName),
	string__int_to_string(TypeArity, A_str).

:- pred rtti__pseudo_type_info_to_string(pseudo_type_info::in, string::out)
	is det.

rtti__pseudo_type_info_to_string(PseudoTypeInfo, Str) :-
	(
		PseudoTypeInfo = type_var(VarNum),
		string__int_to_string(VarNum, Str)
	;
		PseudoTypeInfo = type_ctor_info(RttiTypeId),
		rtti__addr_to_string(RttiTypeId, type_ctor_info, Str)
	;
		PseudoTypeInfo = type_info(RttiTypeId, ArgTypes),
		rtti__mangle_rtti_type_id(RttiTypeId,
			ModuleName, TypeName, A_str),
		ATs_str = pseudo_type_list_to_string(ArgTypes),
		string__append_list([ModuleName, "__type_info_",
			TypeName, "_", A_str, ATs_str], Str)
	;
		PseudoTypeInfo = higher_order_type_info(RttiTypeId, RealArity,
			ArgTypes),
		rtti__mangle_rtti_type_id(RttiTypeId,
			ModuleName, TypeName, _A_str),
		ATs_str = pseudo_type_list_to_string(ArgTypes),
		string__int_to_string(RealArity, RA_str),
		string__append_list([ModuleName, "__ho_type_info_",
			TypeName, "_", RA_str, ATs_str], Str)
	).

:- func pseudo_type_list_to_string(list(pseudo_type_info)) = string.
pseudo_type_list_to_string(PseudoTypeList) =
	string__append_list(list__map(pseudo_type_to_string, PseudoTypeList)).

:- func pseudo_type_to_string(pseudo_type_info) = string.
pseudo_type_to_string(type_var(Int)) =
	string__append("__var_", string__int_to_string(Int)).
pseudo_type_to_string(type_ctor_info(TypeId)) =
	string__append("__type0_", rtti__type_id_to_string(TypeId)).
pseudo_type_to_string(type_info(TypeId, ArgTypes)) =
	string__append_list([
		"__type_", rtti__type_id_to_string(TypeId),
		pseudo_type_list_to_string(ArgTypes)
	]).
pseudo_type_to_string(higher_order_type_info(TypeId, Arity, ArgTypes)) =
	string__append_list([
		"__ho_type_", rtti__type_id_to_string(TypeId),
		"_", string__int_to_string(Arity),
		pseudo_type_list_to_string(ArgTypes)
	]).

:- func rtti__type_id_to_string(rtti_type_id) = string.
rtti__type_id_to_string(RttiTypeId) = String :-
	rtti__mangle_rtti_type_id(RttiTypeId, ModuleName, TypeName, A_Str),
	String0 = string__append_list([ModuleName, "__", TypeName, "_", A_Str]),
	% To ensure that the mapping is one-to-one, and to make demangling
	% easier, we insert the length of the string at the start of the string.
	string__length(String0, Length),
	String = string__format("%d_%s", [i(Length), s(String0)]).

rtti__sectag_locn_to_string(sectag_none,   "MR_SECTAG_NONE").
rtti__sectag_locn_to_string(sectag_local,  "MR_SECTAG_LOCAL").
rtti__sectag_locn_to_string(sectag_remote, "MR_SECTAG_REMOTE").

rtti__type_ctor_rep_to_string(du(standard),
	"MR_TYPECTOR_REP_DU").
rtti__type_ctor_rep_to_string(du(user_defined),
	"MR_TYPECTOR_REP_DU_USEREQ").
rtti__type_ctor_rep_to_string(enum(standard),
	"MR_TYPECTOR_REP_ENUM").
rtti__type_ctor_rep_to_string(enum(user_defined),
	"MR_TYPECTOR_REP_ENUM_USEREQ").
rtti__type_ctor_rep_to_string(notag(standard, equiv_type_is_not_ground),
	"MR_TYPECTOR_REP_NOTAG").
rtti__type_ctor_rep_to_string(notag(user_defined, equiv_type_is_not_ground),
	"MR_TYPECTOR_REP_NOTAG_USEREQ").
rtti__type_ctor_rep_to_string(notag(standard, equiv_type_is_ground),
	"MR_TYPECTOR_REP_NOTAG_GROUND").
rtti__type_ctor_rep_to_string(notag(user_defined, equiv_type_is_ground),
	"MR_TYPECTOR_REP_NOTAG_GROUND_USEREQ").
rtti__type_ctor_rep_to_string(equiv(equiv_type_is_not_ground),
	"MR_TYPECTOR_REP_EQUIV").
rtti__type_ctor_rep_to_string(equiv(equiv_type_is_ground),
	"MR_TYPECTOR_REP_EQUIV_GROUND").
rtti__type_ctor_rep_to_string(unknown,
	"MR_TYPECTOR_REP_UNKNOWN").

