:- module fundeps_1.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.
:- implementation.
:- import_module list.

main(!S) :-
	(
		test(intcoll([0]), 1)
	->
		write_string("yes\n", !S)
	;
		write_string("no\n", !S)
	).

:- typeclass coll(C, E) <= (C -> E) where [
	func e = C,
	func i(C, E) = C,
	pred m(E::in, C::in) is semidet
].

:- type intcoll ---> intcoll(list(int)).

:- instance coll(intcoll, int) where [
	(e = intcoll([])),
	(i(intcoll(Ns), N) = intcoll([N | Ns])),
	m(N, intcoll([N | _])),
	m(N, intcoll([_ | Ns])) :- m(N, intcoll(Ns))
].

:- pred test(C, E) <= coll(C, E).
:- mode test(in, in) is semidet.

test(C, E) :-
	m(E, i(C, E)).
