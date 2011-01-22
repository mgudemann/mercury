%----------------------------------------------------------------------------%
% Copyright (C) 1998-2004, 2006, 2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury Distribution.
%
% Original author: Tom Conway <conway@cs.mu.oz.au>
% Extensions: Ralph Becket <rafe@cs.mu.oz.au>
%
% There's scope for recoding much of this to use the more recent
% additions to the language, if anyone feels like something to do.
%
%----------------------------------------------------------------------------%

:- module moose.
:- interface.

:- import_module io.

%----------------------------------------------------------------------------%

:- pred main(io::di, io::uo) is det.

%----------------------------------------------------------------------------%
%----------------------------------------------------------------------------%

:- implementation.

:- import_module check.
:- import_module grammar.
:- import_module lalr.
:- import_module mercury_syntax.
:- import_module options.
:- import_module tables.

:- import_module array.
:- import_module bool.
:- import_module getopt.
:- import_module int.
:- import_module list.
:- import_module map.
:- import_module pair.
:- import_module require.
:- import_module set.
:- import_module string.
:- import_module term.
:- import_module term_io.
:- import_module varset.

%----------------------------------------------------------------------------%

main(!IO) :-
    parse_options(MOptions, Args, !IO),
    (
        MOptions = ok(Options),
        lookup_bool_option(Options, help, Help),
        ( Help = yes ->
            help(!IO)
        ;
            main2(Options, Args, !IO)
        )
    ;
        MOptions = error(String),
        report_critical_error(String, !IO)
    ).

:- pred report_critical_error(string::in, io::di, io::uo) is det.

report_critical_error(Message, !IO) :-
    io.stderr_stream(StdErr, !IO),
    io.write_string(StdErr, Message, !IO),
    io.nl(StdErr, !IO),
    io.set_exit_status(1, !IO).

:- pred main2(options::in, list(string)::in, io::di, io::uo).

main2(_Options, [], !IO) :-
    report_critical_error("no input files.", !IO),
    help(!IO).
main2(Options, [Name0 | Names], !IO) :-
    figure_out_names(Name0, InName, OutName),
    io.see(InName, Res0, !IO),
    (
        Res0 = ok,
        io.tell(OutName, Res1, !IO),
        (
            Res1 = ok,
            process(Options, !IO),
            io.told(!IO)
        ;
            Res1 = error(Err),
            io.error_message(Err, Msg),
            report_critical_error(Msg, !IO)
        )
    ;
        Res0 = error(Err),
        io.error_message(Err, Msg),
        report_critical_error(Msg, !IO)
    ),
    ( Names = [_|_] ->
        main2(Options, Names, !IO)
    ;
        true    
    ).

:- pred figure_out_names(string::in, string::out, string::out) is det.

figure_out_names(Name0, InName, OutName) :-
    ( string.remove_suffix(Name0, ".moo", Name1) ->
        Name = Name1
    ;
        Name = Name0
    ),
    string.append(Name, ".moo", InName),
    string.append(Name, ".m", OutName).

:- type whereami
    --->    (interface) ; (implementation) .

:- type parser
    --->    parser(
            whereami,
            nonterminal,    % Starting nonterminal.
            term,           % EOF token.
            string,         % Token type name.
            string,         % Naming prefix (unused).
            string,         % Parser state input mode.
            string          % Parser state output mode.
        ).

:- pred process(options::in, io.state::di, io.state::uo) is det.

process(Options, !IO) :-
    lookup_bool_option(Options, verbose, Verbse),
    ( Verbse = yes -> report_stats(!IO) ; true ),
    read_module(Result, !IO),
    Result = module(Module, Errors),
    (
        Errors = [_|_],
        io.stderr_stream(StdErr, !IO),
        list.foldl((pred(Err::in, !.IO::di, !:IO::uo) is det :-
            Err = error(Msg, Line),
            io.format(StdErr, "%d: %s\n", [i(Line), s(Msg)], !IO)
        ), Errors, !IO),
        io.set_exit_status(1, !IO)
    ;
        Errors = [],
        get_moose_elements(Module, [], Remainder0, (implementation),
            [], MParser, [], RuleDecls, [], ClauseList,
            [], XFormList),
        (
            MParser = [],
            report_critical_error("error: no parse/6 declaration.", !IO)
        ;
            MParser = [Parser],
            list.reverse(Remainder0, Remainder),
            process_2(Options, Remainder, Parser,
                RuleDecls, ClauseList, XFormList, !IO)
        ;
            MParser = [_,_|_],
            report_critical_error("error: more than one parse/4 declaration.",
                !IO)
        )
    ).

:- pred process_2(options, (module), parser, list(rule_decl), list(clause),
        list(xform), io, io).
:- mode process_2(in, in, in, in, in, in, di, uo) is det.

process_2(Options, Module, Parser, Decls0, Clauses0, XFormList, !IO) :-
    lookup_bool_option(Options, verbose, Verbse),
    ( Verbse = yes -> report_stats(!IO) ; true ),

    check_rule_decls(Decls0, Decls, DeclErrors),
    list.foldl(write_error, DeclErrors, !IO),

    check_clauses(Clauses0, Decls, Clauses, ClauseErrors),
    list.foldl(write_error, ClauseErrors, !IO),

    Parser = parser(WhereAmI, StartId, EndTerm, TokenType, _Prefix, InAtom, 
        OutAtom),

    check_useless(StartId, Clauses, Decls, UselessErrors),
    list.foldl(write_error, UselessErrors, !IO),

    check_inf_derivations(Clauses, Decls, InfErrors),
    list.foldl(write_error, InfErrors, !IO),

    (
        DeclErrors = [],
        ClauseErrors = [],
        UselessErrors = [],
        InfErrors = [] 
    ->
        write_module(nolines, Module, !IO), io.nl(!IO),
        map.lookup(Decls, StartId, StartDecl),
        write_parser(WhereAmI, StartId, StartDecl, TokenType,
                InAtom, OutAtom, !IO),
        write_action_type_class(WhereAmI, XFormList, Decls,
                TokenType, InAtom, OutAtom, !IO),

        io.stderr_stream(StdErr, !IO),
        io.write_string(StdErr, "constructing grammar...\n", !IO),

        map.init(Xfns0),
        list.foldl((pred(XForm::in, Xf0::in, Xf::out) is det :-
            XForm = xform(XfNt, _),
            map.det_insert(Xf0, XfNt, XForm, Xf)
        ), XFormList, Xfns0, XForms),

        construct_grammar(StartId, Clauses, XForms, Grammar),
        Grammar = grammar(Rules, _, Xfns, _, Index, First, _Follow),
        reaching(Rules, First, Reaching),

        io.write_string(StdErr, "constructing lr(0) items...\n", !IO),
        lr0items(Rules, Reaching, C, Gotos),
        io.write_string(StdErr, "determining lookaheads...\n", !IO),
        lookaheads(C, Gotos, Rules, First, Index, Lookaheads, !IO),
        io.write_string(StdErr, "computing the action table...\n", 
            !IO),
        shifts(C, Rules, First, Reaching, Shifts),
        actions(C, Rules, Lookaheads, Gotos, Shifts, States, 
            ActionTable, ActionErrs),
        list.foldl2(
            (pred(Err::in, HasEs0::in, HasEs::out, !.IO::di, 
                !:IO::uo) is det :-
            (
                Err = warning(Warning),
                HasEs = HasEs0,
                (
                    Warning = shiftreduce(_S, Rp),
                    io.write_string(StdErr,
                "shift reduce conflict involving:\n\t", !IO),
                    write_rule(StdErr, Rp, Rules, !IO)
                )
            ;
                Err = error(Error),
                HasEs = yes,
                (
                    Error = shiftshift(_, _),
                    io.write_string(StdErr, 
                        "shift shift error.\n", !IO)
                ;
                    Error = reducereduce(R0, R1),
                    io.write_string(StdErr, 
                    "reduce reduce conflict involving:\n\t",
                        !IO),
                    write_rule(StdErr, R0, Rules, !IO),
                    io.write_string(StdErr, "\t", !IO),
                    write_rule(StdErr, R1, Rules, !IO)
                ;
                    Error = misc(Ac1, Ac2),
                    io.write_string(StdErr, 
                        "misc conflict involving:\n\t",
                         !IO),
                    io.write(StdErr, Ac1, !IO), 
                    io.write_string(StdErr, "\n\t", !IO),
                    io.write(StdErr, Ac2, !IO), 
                    io.write_string(StdErr, "\n", !IO)
                ),
                io.set_exit_status(1, !IO)
            )
        ), ActionErrs, no, _HasErrors, !IO),
        write_action_table(ActionTable, TokenType, EndTerm, !IO),
        io.write_string(StdErr, "computing the goto table...\n", !IO),
        gotos(C, States, Gotos, GotoTable),
        write_goto_table(GotoTable, Decls, !IO),
        write_reductions(Rules, ActionTable, TokenType, InAtom, 
            OutAtom, Xfns, !IO)
    ;
        % XXX: What is this condition?  Should an exception be thrown here?!?
        true,
        io.set_exit_status(1, !IO)
    ).

%------------------------------------------------------------------------------%

:- pred write_action_type_class(whereami, list(xform), rule_decls, 
    string, string, string, io, io).
:- mode write_action_type_class(in, in, in, in, in, in, di, uo) is det.

write_action_type_class(Where, XForms, Decls, TokenType, InAtom, OutAtom, 
        !IO) :-        
    ( Where = (interface) ->
        io.write_string(":- interface.\n\n", !IO)
    ;
        true    
    ),
    io.format("\
:- typeclass parser_state(T) where [
    pred get_token(%s, T, T),
    mode get_token(out, %s, %s) is det,
    func unget_token(%s, T) = T,
    mode unget_token(in, %s) = %s is det\
",
        [s(TokenType), s(InAtom), s(OutAtom),
         s(TokenType), s(InAtom), s(OutAtom)], !IO
    ),
    ( not XForms = [] ->
        io.write_string(",\n", !IO)
    ;
        true    
    ),
    WriteIn = (pred(_Anything::in, !.IO::di, !:IO::uo) is det :-
        io.write_string("in", !IO)
    ),
    WriteXForm = (pred(XForm::in, !.IO::di, !:IO::uo) is det :-
        XForm = xform(NT, MethodName),
        map.lookup(Decls, NT, RuleDecl),
        RuleDecl = rule(_NT, Types, VarSet, _Context),
        io.format("\tfunc %s(", [s(MethodName)], !IO),
        io.write_list(Types, ", ", term_io.write_term(VarSet), !IO),
        ( Types \= [] -> io.write_string(", ", !IO) ; true ),
        io.write_string("T) = T,\n", !IO),

        io.format("\tmode %s(", [s(MethodName)], !IO),
        io.write_list(Types, ", ", WriteIn, !IO),
        ( Types \= [] -> io.write_string(", ", !IO) ; true ),
        io.format("%s) = %s is det", [s(InAtom), s(OutAtom)], !IO)
    ),
    io.write_list(XForms, ",\n", WriteXForm, !IO),
    io.write_string("\n].\n", !IO),
    ( Where = (interface) ->
        io.write_string(":- implementation.\n\n", !IO)
    ;
        true    
    ).

%------------------------------------------------------------------------------%

:- pred write_rule(output_stream, int, rules, io, io).
:- mode write_rule(in, in, in, di, uo) is det.

write_rule(Stream, RN, Rules, !IO) :-
    map.lookup(Rules, RN, Rule),
    io.write_int(Stream, RN, !IO), 
    io.write_string(Stream, ": ", !IO),
    Rule = rule(NT, _, Syms, _, _, _, _),
    io.write(Stream, NT, !IO),
    io.write_string(Stream, " ->\t", !IO),
    write_syms(Stream, 0, 999, Syms, !IO),
    io.write_string(Stream, "\n", !IO).

:- pred write_syms(output_stream, int, int, symbols, io, io).
:- mode write_syms(in, in, in, in, di, uo) is det.

write_syms(Stream, N, Dot, Syms, !IO) :-
    ( N = Dot ->
        io.write_string(Stream, ". ", !IO)
    ;
        true
    ),
    array.max(Syms, Max),
    ( N =< Max ->
        array.lookup(Syms, N, Sym),
        io.write(Stream, Sym, !IO),
        io.write_string(Stream, " ", !IO),
        write_syms(Stream, N + 1, Dot, Syms, !IO)
    ;
        true    
    ).

%------------------------------------------------------------------------------%

:- pred get_moose_elements((module), (module), (module), whereami,
        list(parser), list(parser), list(rule_decl), list(rule_decl),
        list(clause), list(clause), list(xform), list(xform)).
:- mode get_moose_elements(in, in, out, in, in, out, in, out, in, out,
        in, out) is det.

get_moose_elements([], !Remainder, _, !MParser, !RuleDecls, !Clauses, !Actions).
get_moose_elements([Element | Elements], !Remainder, !.WhereAmI, !MParser, 
        !RuleDecls, !Clauses, !Actions) :-
    (
        Element = misc(ClauseTerm, ClauseVarSet),
        term_to_clause(ClauseTerm, ClauseVarSet, _, Clause)
    ->
        list.append([Clause], !Clauses)
    ;
        Element = misc(MiscTerm0, _),
        interface_term(MiscTerm0)
    ->
        !:WhereAmI = (interface),
        list.append([Element], !Remainder)    
    ;
        Element = misc(MiscTerm1, _),
        implementation_term(MiscTerm1)
    ->
        !:WhereAmI = (implementation),
        list.append([Element], !Remainder)
    ;
        Element = misc(MiscTerm2, MiscVarSet2),
        rule_term(MiscTerm2, MiscVarSet2, RuleDecl)
    ->
        list.append([RuleDecl], !RuleDecls)
    ;
        Element = misc(MiscTerm3, MiscVarSet3),
        parser_term(MiscTerm3, MiscVarSet3, !.WhereAmI, Parser)
    ->
        list.append([Parser], !MParser)
    ;
        Element = misc(MiscTerm4, _),
        xform_term(MiscTerm4, XForm)
    ->
        list.append([XForm], !Actions)
    ;
        list.append([Element], !Remainder)
    ),
    get_moose_elements(Elements, !Remainder, !.WhereAmI, !MParser, 
        !RuleDecls, !Clauses, !Actions).

:- pred interface_term(term::in) is semidet.

interface_term(functor(atom(":-"), [functor(atom("interface"), [], _)], _)).

:- pred implementation_term(term::in) is semidet.

implementation_term(functor(atom(":-"), 
    [functor(atom("implementation"), [], _)], _)).

:- pred rule_term(term, varset, rule_decl).
:- mode rule_term(in, in, out) is semidet.

rule_term(functor(atom(":-"), [functor(atom("rule"), [RuleTerm], _)], _),
        VarSet, Decl) :-
    RuleTerm = functor(atom(Name), Args, Context),
    list.length(Args, Arity),
    Decl = rule(Name/Arity, Args, VarSet, Context).

:- pred parser_term(term, varset, whereami, parser).
:- mode parser_term(in, in, in, out) is semidet.

parser_term(functor(atom(":-"), [functor(atom("parse"), Args, _)], _),
        _VarSet, WhereAmI, Decl) :-
    Args = [StartIdTerm, TokTerm, EndTerm, PrefixTerm, InAtomTerm, 
        OutAtomTerm],
    StartIdTerm = functor(atom("/"), [functor(atom(Name), [], _),
        functor(integer(Arity), _, _)], _),
    StartId = Name / Arity,
    TokTerm = functor(atom(TokAtom), [], _),
    PrefixTerm = functor(atom(PrefixAtom), [], _),
    InAtomTerm = functor(atom(InAtom), [], _),
    OutAtomTerm = functor(atom(OutAtom), [], _),
    Decl = parser(WhereAmI, StartId, EndTerm, TokAtom, PrefixAtom, InAtom, 
        OutAtom).

:- pred xform_term(term, xform).
:- mode xform_term(in, out) is semidet.

xform_term(Term, XForm) :-
    Term = functor(atom(":-"), [
        functor(atom("action"), [
            functor(atom("/"), [
                functor(atom(Name), [], _),
                functor(integer(Arity), _, _)
            ], _),
            functor(atom(Pred), [], _)
        ], _)
    ], _),
    XForm = xform(Name/Arity, Pred).

%------------------------------------------------------------------------------%

:- pred help(io, io).
:- mode help(di, uo) is det.

help(!IO) :-
    io.stderr_stream(StdErr, !IO),
    io.write_string(StdErr, "\
usage: moose <options> file ...
    -h|--help        help
    -a|--dump-action    dump the action table
    -f|--dump-first        dump the FIRST sets
    -a|--dump-follow    dump the FOLLOW sets
    -a|--dump-goto        dump the goto table
    -a|--dump-items        dump the item sets
    -a|--dump-rules        dump the flattened rules
", !IO).

%------------------------------------------------------------------------------%

:- pred write_action_table(actiontable, string, term, io, io).
:- mode write_action_table(in, in, in, di, uo) is det.

write_action_table(Table, TT, End, !IO) :-
    io.format(":- inst state_no --->\n\t\t", [], !IO),
    io.write_list(map.keys(Table), "\n\t;\t", io.write_int, !IO),
    io.format(".\n:- inst state_nos == list_skel(state_no).\n\n", [], !IO),
    io.format("\
:- type parsing_action
    --->    shift
    ;    reduce
    ;    accept.

:- pred actions(int, %s, parsing_action, int).
:- mode actions(in(state_no), in, out, out(state_no)) is semidet.

",
        [s(TT)],
    !IO),
    map.foldl((pred(State::in, StateActions::in, !.IO::di, 
            !:IO::uo) is det :-
        string.format("0x%x", [i(State)], SS),
        io.format("\
actions(%s, Tok, Action, Value) :-
    actions%s(Tok, Action, Value).

:- pred actions%s(%s, parsing_action, int).
:- mode actions%s(in, out, out(state_no)) is semidet.

",
            [s(SS), s(SS), s(SS), s(TT), s(SS)],
        !IO),
        write_state_actions(SS, End, StateActions, !IO)
    ), Table, !IO).

:- pred write_state_actions(string, term, map(terminal, action),
        io, io).
:- mode write_state_actions(in, in, in, di, uo) is det.

write_state_actions(SS, End, StateActions, !IO) :-
    string.format("actions%s", [s(SS)], Name),
    map.foldl((pred(Terminal::in, Action::in, !.IO::di, !:IO::uo) is det :-
        terminal_to_term(Terminal, End, Token),
        term.context_init(Ctxt),
        Term = functor(atom(Name),
            [Token,
            functor(atom(Kind), [], Ctxt),
            functor(integer(Val), [], Ctxt)], Ctxt),
        (
            Action = shift(Val),
            Kind = "shift"
        ;
            Action = reduce(Val), 
            Kind = "reduce"
        ;
            Action = accept,
            Kind = "accept",
            Val = 0
        ),
        varset.init(Varset),
        term_io.write_term_nl(Varset, Term, !IO)
    ), StateActions, !IO),
    io.nl(!IO).

:- pred terminal_to_term(terminal, term, term).
:- mode terminal_to_term(in, in, out) is det.

terminal_to_term(epsilon, _, _) :-
    error("terminal_to_term: unexpected epsilon").
terminal_to_term(Name/Arity, _, Term) :-
    varset.init(V0),
    varset.new_vars(V0, Arity, Vars, _),
    term.context_init(Ctxt),
    list.map((pred(Var::in, T::out) is det :-
        T = variable(Var, Ctxt)
    ), Vars, Args),
    Term = functor(atom(Name), Args, Ctxt).
terminal_to_term(($), End, End).
terminal_to_term((*), _, _) :-
    error("terminal_to_term: unexpected hash").

%------------------------------------------------------------------------------%

:- pred write_goto_table(gototable, rule_decls, io, io).
:- mode write_goto_table(in, in, di, uo) is det.

write_goto_table(Table, DeclTable, !IO) :-
    map.values(DeclTable, Decls),
    write_nonterminal_type(Decls, !IO),
    io.write_string("\
:- pred gotos(int, nonterminal, int).
:- mode gotos(in(state_no), in, out(state_no)) is semidet.

", !IO),
    WriteGotos = (pred(State::in, Actions::in, !.IO::di, !:IO::uo) is det :-
        string.format("0x%x", [i(State)], SS),
        io.format("\
gotos(%s, NT, NS) :-
    gotos%s(NT, NS).

:- pred gotos%s(nonterminal, int).
:- mode gotos%s(in, out) is semidet.

",
            [s(SS), s(SS), s(SS), s(SS)], !IO),
        write_state_gotos(SS, Actions, !IO)
    ),    
    map.foldl(WriteGotos, Table, !IO).

:- pred write_nonterminal_type(list(rule_decl), io, io).
:- mode write_nonterminal_type(in, di, uo) is det.

write_nonterminal_type(Ds, !IO) :-
    list.map((pred(Decl::in, NTType::out) is det :-
        Decl = rule(NT, Args, _VS, TC),
        (
            NT = start,
            error("write_nonterminal_type: start!")
        ;
            NT = Name/_Arity
        ),
        NTType = functor(atom(Name), Args, TC)
    ), Ds, NTTypes),
    term.context_init(Ctxt),
    varset.init(Varset),
    Type = disj(functor(atom("nonterminal"), [], Ctxt), NTTypes),
    Element = type(Type, Varset),
    write_element(nolines, Element, !IO),
    io.nl(!IO).

:- pred write_state_gotos(string, map(nonterminal, grammar.state), io, io).
:- mode write_state_gotos(in, in, di, uo) is det.

write_state_gotos(SS, StateActions, !IO) :-
    string.format("gotos%s", [s(SS)], Name),
    map.foldl((pred(NT::in, NS::in, !.IO::di, !:IO::uo) is det :-
        nonterminal_to_term(NT, Token),
        term.context_init(Ctxt),
        Term = functor(atom(Name),
            [Token, functor(integer(NS), [], Ctxt)], Ctxt),
        varset.init(Varset),
        term_io.write_term_nl(Varset, Term, !IO)
    ), StateActions, !IO),
    io.nl(!IO).

:- pred nonterminal_to_term(nonterminal, term).
:- mode nonterminal_to_term(in, out) is det.

nonterminal_to_term(start, _) :-
    error("nonterminal_to_term: unexpected start").
nonterminal_to_term(Name/Arity, Term) :-
    varset.init(V0),
    varset.new_vars(V0, Arity, Vars, _),
    term.context_init(Ctxt),
    list.map((pred(Var::in, T::out) is det :-
        T = variable(Var, Ctxt)
    ), Vars, Args),
    Term = functor(atom(Name), Args, Ctxt).

%------------------------------------------------------------------------------%

:- pred write_parser(whereami, nonterminal, rule_decl, string, string, string,
        io, io).
:- mode write_parser(in, in, in, in, in, in, di, uo) is det.

write_parser(Where, NT, Decl, _TT, InAtom, OutAtom, !IO) :-
    (
        NT = StartName/StartArity
    ;
        NT = start,
        error("write_parser: start!")
    ),
    Decl = rule(_, DeclArgs, DeclVarset, DeclCtxt),
    varset.init(Varset0),
    mkstartargs(StartArity, [], StartArgs, Varset0, Varset),
    StartTerm = functor(atom(StartName), StartArgs, Ctxt),
    term.context_init(Ctxt),
    ParseResultType = type(disj(functor(atom("parse_result"), [], Ctxt),
        [OkayType, ErrorType]), DeclVarset),
    OkayType = functor(atom(StartName), DeclArgs, DeclCtxt),
    ErrorType = functor(atom("error"), [
        functor(atom("string"), [], Ctxt)], Ctxt),
    ( Where = (interface) ->
        io.write_string(":- interface.\n\n", !IO)
    ;
        true    
    ),
    write_element(nolines, ParseResultType, !IO),
    io.nl(!IO),
    io.format("\
:- pred parse(parse_result, P, P) <= parser_state(P).
:- mode parse(out, %s, %s) is det.

",
        [s(InAtom), s(OutAtom)],
    !IO),
    ( Where = (interface) ->
        io.write_string(":- implementation.\n\n", !IO)
    ;
        true    
    ),
    io.format("\
:- import_module list.

parse(Result, Toks0, Toks) :-
    parse(Toks0, Toks, [0], [], Result).

:- pred parse(P, P, statestack, symbolstack, parse_result) <= parser_state(P).
:- mode parse(%s, %s, in(state_nos), in, out) is det.

parse(Toks0, Toks, St0, Sy0, Res) :-
    (
        St0 = [S0|_],
        get_token(Tok, Toks0, Toks1),
        ( 
            actions(S0, Tok, What, Val)
        ->
            (
                What = shift,
                Sy1 = [t(Tok)|Sy0],
                St1 = [Val|St0],
                parse(Toks1, Toks, St1, Sy1, Res)
            ;
                What = reduce,
        Toks2 = unget_token(Tok, Toks1),
                reduce(Val, St0, St1, Sy0, Sy1, Toks2, Toks3),
                parse(Toks3, Toks, St1, Sy1, Res)
            ;
                What = accept,
                    ( Sy0 = [n(",
        [s(InAtom), s(OutAtom)],
        !IO),
        term_io.write_term(Varset, StartTerm, !IO),
        io.write_string(")] ->
                            Res = (",
    !IO),
    term_io.write_term(Varset, StartTerm, !IO),
    io.write_string("),
                            Toks = Toks1
                    ;
                            error(""parse: internal accept error"")
                    )
                )
        ;
            Res = error(""parse error""),
        Toks = unget_token(Tok, Toks1)
        )
    ;
        St0 = [],
        error(""parse: state stack underflow"")
    ).
",
    !IO).

:- pred mkstartargs(int, list(term), list(term), varset, varset).
:- mode mkstartargs(in, in, out, in, out) is det.

mkstartargs(N, !Terms, !Varset) :-
    ( N =< 0 ->
        true
    ;
        string.format("V%d", [i(N)], VarName),
        varset.new_named_var(!.Varset, VarName, Var, !:Varset),
        Term = term.variable(Var, context_init),
        list.append([Term], !Terms),
        mkstartargs(N - 1, !Terms, !Varset)
    ).

%------------------------------------------------------------------------------%

:- pred write_reductions(rules, actiontable, string, string, string, xforms,
        io, io).
:- mode write_reductions(in, in, in, in, in, in, di, uo) is det.

write_reductions(Rules, Table, TT, InAtom, OutAtom, Xfns, !IO) :-
    io.format("\
:- import_module require, std_util.

:- type statestack == list(int).
:- type symbolstack == list(stacksymbol).
:- type stacksymbol
    --->    n(nonterminal)
    ;    t(%s).

",
        [s(TT)],
    !IO),
    io.format("
:- pred reduce(int, statestack, statestack,
        symbolstack, symbolstack, P, P) <= parser_state(P).
:- mode reduce(in(state_no), in(state_nos), out(state_nos),
        in, out, %s, %s) is det.

reduce(RuleNum, States0, States, Symbols0, Symbols, Tokens0, Tokens) :-
    reduce0(RuleNum, States0, States1, Symbols0, Symbols1,
        Tokens0, Tokens1),
    (
        States1 = [State0|_States2],
        Symbols1 = [n(Non)|_],
        gotos(State0, Non, State1),
        States3 = [State1|States1]
    ->
        States = States3,
        Symbols = Symbols1,
        Tokens = Tokens1
    ;
        error(""reduce: reduction failed"")
    ).

",
        [s(InAtom), s(OutAtom)],
    !IO),
    io.format("\
:- pred reduce0(int, statestack, statestack,
        symbolstack, symbolstack, P, P) <= parser_state(P).
:- mode reduce0(in(state_no), in(state_nos), out(state_nos),
        in, out, %s, %s) is det.

",
        [s(InAtom), s(OutAtom)],
    !IO),
    map.foldl((pred(Rn::in, Rule::in, !.IO::di, !:IO::uo) is det :-
        ( Rn = 0 ->

        io.write_string("\
reduce0(0x0, _, _, _, _, _, _) :-
    reduce0_error(0x0).

",
        !IO)

        ;

        RedName = string.format("reduce0x%x", [i(Rn)]),
        RnS     = string.format("0x%x", [i(Rn)]),
        io.format("\
reduce0(%s, S0, S, T0, T, U0, U) :-
    %s(S0, S, T0, T, U0, U).

:- pred %s(statestack, statestack, symbolstack, symbolstack,
        P, P) <= parser_state(P).
:- mode %s(in(state_nos), out(state_nos), in, out, %s, %s) is det.
",
            [s(RnS), s(RedName), s(RedName), s(RedName), 
                s(InAtom), s(OutAtom)],
            !IO),
        Rule = rule(RNt, Head, _, Body, Actions, Varset0, _C),
        term.context_init(Ctxt),
        varset.new_named_var(Varset0, "M_St0", St0v, Varset1),
        St0 = variable(St0v, Ctxt),
        varset.new_named_var(Varset1, "M_St1", St1v, Varset2),
        St1 = variable(St1v, Ctxt),
        varset.new_named_var(Varset2, "M_Sy0", Sy0v, Varset3),
        Sy0 = variable(Sy0v, Ctxt),
        varset.new_named_var(Varset3, "M_Sy1", Sy1v, Varset4),
        Sy1 = variable(Sy1v, Ctxt),
        varset.new_named_var(Varset4, "M_RedRes", Resv, Varset5),
        Res = variable(Resv, Ctxt),
        ResS = functor(atom("n"), [variable(Resv, Ctxt)], Ctxt),
        varset.new_named_var(Varset5, "M_D", Dv, Varset6),
        _D = variable(Dv, Ctxt),
        varset.new_named_var(Varset6, "M_S", Sv, Varset7),
        _S = variable(Sv, Ctxt),
        varset.new_named_var(Varset7, "M_St", Stv, Varset8),
        St = variable(Stv, Ctxt),
        varset.new_named_var(Varset8, "M_Sy", Syv, Varset9),
        Sy = variable(Syv, Ctxt),
        varset.new_named_var(Varset9, "M_Ts0", Ts0v, Varset10),
        Ts0 = variable(Ts0v, Ctxt),
        varset.new_named_var(Varset10, "M_Ts", Tsv, Varset11),
        Ts = variable(Tsv, Ctxt),
        string.format("reduction 0x%x failed!", [i(Rn)], Err),
        mkstacks(Body, St1, Sts, Sy1, Sys, Varset11, Varset12),
        Cond = functor(atom(","), [
            functor(atom("="), [St0, Sts], Ctxt),
            functor(atom("="), [Sy0, Sys], Ctxt)
        ], Ctxt),
        Red = functor(atom("="), [Res, Head], Ctxt),
        list.append(Actions, [Red], AllActions0),
        list.reverse(AllActions0, AllActions),
        ConsStack = functor(atom(","), [
            functor(atom("="), [Sy, functor(atom("[|]"),
                [ResS, Sy1], Ctxt)], Ctxt),
            functor(atom("="), [St, St1], Ctxt)], Ctxt),
        mkactions(AllActions, ConsStack, Then0),
        (
            map.search(Xfns, RNt, xform(_, XFormName)),
            Head = functor(_, HeadArgs, _)
        ->
            list.append(HeadArgs, [Ts0], Then1Args),
            XFTerm = functor(atom(XFormName), Then1Args, Ctxt)
        ;
            XFTerm = Ts0
        ),
        Then1 = functor(atom("="), [Ts, XFTerm], Ctxt),
        Then = functor(atom(","), [Then0, Then1], Ctxt),
        BodyTerm = functor(atom(";"),[
            functor(atom("->"), [
                Cond,
                Then
            ], Ctxt),
            functor(atom("error"),
                [functor(string(Err), [], Ctxt)],
                Ctxt
            )], Ctxt),
        ( term_to_goal(BodyTerm, Goal0) ->
            Goal = Goal0
        ;
            error("write_reductions: failed to convert goal")
        ),
        Clause = clause(
            functor(atom(RedName),  [St0, St, Sy0, Sy, Ts0, Ts], 
                Ctxt), 
            Goal, Varset12),
        write_element(lines, Clause, !IO),
        io.nl(!IO)
        )
    ), Rules, !IO),
    WriteReduceError = (pred(State::in, _::in, !.IO::di, !:IO::uo) is det :-
        ( if    not map.contains(Rules, State)
          then    
                io.format("\
reduce0(0x%x, _, _, _, _, _, _) :-
    reduce0_error(0x%x).

", 
                [i(State), i(State)], !IO)
            else    true
        )
    ),
    map.foldl(WriteReduceError, Table, !IO),
    io.format("\
:- pred reduce0_error(int).
:- mode reduce0_error(in) is erroneous.

reduce0_error(State) :-
    error(string.format(""reduce in state 0x%%x"", [i(State)])).

", [], !IO).

:- pred mkstacks(list(bodyterm), term, term, term, term, varset, varset).
:- mode mkstacks(in, in, out, in, out, in, out) is det.

mkstacks([], !St, !Sy, !VS).
mkstacks([E0 | Es], !St, !Sy, !VS) :-
    varset.new_var(!.VS, U, !:VS),
    term.context_init(Ctxt),
    (
        E0 = terminal(ET),
        E = functor(atom("t"), [ET], Ctxt)
    ;
        E0 = nonterminal(EN),
        E = functor(atom("n"), [EN], Ctxt)
    ),
    !:Sy = functor(atom("[|]"), [E, !.Sy], Ctxt),
    !:St = functor(atom("[|]"), [variable(U, Ctxt), !.St], Ctxt),
    mkstacks(Es, !St, !Sy, !VS).

:- pred mkactions(list(term), term, term).
:- mode mkactions(in, in, out) is det.

mkactions([], !Term).
mkactions([E | Es], !Term) :-
    term.context_init(Ctxt),
    !:Term = functor(atom(","), [E, !.Term], Ctxt),
    mkactions(Es, !Term).

%------------------------------------------------------------------------------%

:- pred sub(string, list(pair(string)), string).
:- mode sub(in, in, out) is det.

sub(Orig, Subs, Final) :-
    list.foldl((pred(Sub::in, S0::in, S1::out) is det :-
        Sub = From - To,
        string.replace_all(S0, From, To, S1)
    ), Subs, Orig, Final).

