%---------------------------------------------------------------------------%
% vim: ts=4 sw=4 et ft=mercury
%---------------------------------------------------------------------------%

:- module missing_init_pred.

:- interface.

:- solver type t.

:- implementation.

:- solver type t
    where   representation is int,
            initialisation is init,
            ground is ground,
            any is ground.
