%----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%----------------------------------------------------------------------------%
% Copyright (C) 2013 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%----------------------------------------------------------------------------%
%
% File: mfilterjavac.m
% Author: pbone
%
% This program processes the output of the Java compiler when compiling Java
% code generated by the Mercury compiler.  It translates the error contexts
% reported by the Java compiler into the corresponding error contexts in the
% Mercury source file.  This is done by looking for special comments
% inserted into the generated Java code by the Mercury compiler.  (See
% compiler/mlds_to_java.m for details.)
%
%-----------------------------------------------------------------------------%

:- module mfilterjavac.
:- interface.

:- import_module io.

%-----------------------------------------------------------------------------%

:- pred main(io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module char.
:- import_module int.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module require.
:- import_module string.

%-----------------------------------------------------------------------------%

main(!IO) :-
    filter_lines(MaybeError, map.init, _, !IO),
    (
        MaybeError = ok
    ;
        MaybeError = error(Error),
        io.write_string(io.stderr_stream, Error, !IO),
        io.set_exit_status(1, !IO)
    ).

:- pred filter_lines(maybe_error::out,
    line_info_cache::in, line_info_cache::out, io::di, io::uo) is det.

filter_lines(MaybeError, !Cache, !IO) :-
    io.read_line_as_string(Result, !IO),
    (
        Result = ok(Line),
        filter_line(Line, MaybeOutLine, !Cache, !IO),
        (
            MaybeOutLine = ok(OutLine),
            io.write_string(OutLine, !IO),
            filter_lines(MaybeError, !Cache, !IO)
        ;
            MaybeOutLine = error(Error),
            MaybeError = error(Error)
        )
    ;
        Result = eof,
        MaybeError = ok
    ;
        Result = error(Error),
        ErrorStr = format("stdin: %s\n", [s(error_message(Error))]),
        MaybeError = error(ErrorStr)
    ).

:- pred filter_line(string::in, maybe_error(string)::out,
    line_info_cache::in, line_info_cache::out, io::di, io::uo) is det.

filter_line(Line, MaybeOutLine, !Cache, !IO) :-
    (
        PartsA = split_at_separator(char.is_whitespace, Line),
        PartsA = [PartAA | OtherPartsA],
        PartsAA = split_at_char(':', PartAA),
        PartsAA = [Filename, LineStr, Empty],
        string.to_int(LineStr, LineNo),
        Empty = ""
    ->
        ( map.search(!.Cache, Filename, LineInfo) ->
            translate_and_outpot_line(LineInfo, Filename, LineNo,
                OtherPartsA, OutLine),
            MaybeOutLine = ok(OutLine)
        ;
            maybe_get_line_info(Filename, MaybeLineInfoErr, !IO),
            (
                MaybeLineInfoErr = ok(LineInfo),
                map.det_insert(Filename, LineInfo, !Cache),
                translate_and_outpot_line(LineInfo, Filename, LineNo,
                    OtherPartsA, OutLine),
                MaybeOutLine = ok(OutLine)
            ;
                MaybeLineInfoErr = error(Error),
                MaybeOutLine = error(Error)
            )
        )
    ;
        MaybeOutLine = ok(Line)
    ).

:- pred translate_and_outpot_line(list(line_info)::in, string::in, int::in,
    list(string)::in, string::out) is det.

translate_and_outpot_line(LineInfo, Filename, LineNo, RestParts, OutLine) :-
    line_info_translate(LineInfo, Filename, LineNo, MerFileName, MerLineNo),
    Rest = string.join_list(" ", RestParts),
    OutLine = string.format("%s:%d: %s\n",
        [s(MerFileName), i(MerLineNo), s(Rest)]).

%-----------------------------------------------------------------------------%

:- type line_info
    --->    line_info(
                li_start        :: int, % inclusive
                li_end          :: int, % not inclusive
                li_delta        :: int,
                li_orig_file    :: string
            ).

:- type line_info_error
    --->    line_info_error(
                li_filename     :: string,
                li_lineno       :: int,
                li_error        :: line_info_error_type
            ).

:- type line_info_error_type
    --->    lie_end_without_beginning
    ;       lie_beginning_without_end
    ;       lie_duplicate_beginning.

:- type line_info_cache == map(string, list(line_info)).

:- pred line_info_translate(list(line_info)::in, string::in, int::in,
    string::out, int::out) is det.

line_info_translate([], Name, Line, Name, Line).
line_info_translate([Info | Infos], Name0, Line0, Name, Line) :-
    Info = line_info(Start, End, Delta, File),
    (
        Line0 < Start
    ->
        % No translation.
        Name = Name0,
        Line = Line0
    ;
        Line0 < End
    ->
        Line = Line0 + Delta,
        Name = File
    ;
        line_info_translate(Infos, Name0, Line0, Name, Line)
    ).

:- func error_type_string(line_info_error_type) = string.

error_type_string(lie_end_without_beginning) =
    "END token without BEGIN token".
error_type_string(lie_beginning_without_end) =
    "BEGIN token without END token".
error_type_string(lie_duplicate_beginning) =
    "BEGIN token followed by another BEGIN token".

%----------------------------------------------------------------------------%

:- pred maybe_get_line_info(string::in, maybe_error(list(line_info))::out,
    io::di, io::uo) is det.

maybe_get_line_info(Filename, MaybeInfo, !IO) :-
    io.open_input(Filename, Res, !IO),
    (
        Res = ok(Stream),
        read_line_marks(Stream, 1, [], MaybeMarksRev, !IO),
        io.close_input(Stream, !IO),
        (
            MaybeMarksRev = ok(MarksRev),
            reverse(MarksRev, Marks),
            create_line_info(Marks, Filename, [], MaybeInfo0),
            (
                MaybeInfo0 = ok(Infos),
                MaybeInfo = ok(Infos)
            ;
                MaybeInfo0 = error(LineInfoError),
                LineInfoError = line_info_error(ErrFilename, ErrLine, Error),
                StringError = format(
                    "%s:%d: Error understanding line number declration: %s",
                    [s(ErrFilename), i(ErrLine), s(error_type_string(Error))]),
                MaybeInfo = error(StringError)
            )
        ;
            MaybeMarksRev = error(Msg),
            MaybeInfo = error(format("%s: %s", [s(Filename), s(Msg)]))
        )
    ;
        Res = error(_Error),
        % We ignore errors here as our parsing of javac's output could cause
        % false errors.
        MaybeInfo = ok([])
    ).

:- type line_mark
    --->    line_mark(
                lm_type             :: begin_or_end_block,
                lm_mer_file         :: string,
                lm_java_line_no     :: int,
                lm_mer_line_no      :: int
            ).

:- type begin_or_end_block
    --->    begin_block
    ;       end_block.

:- pred read_line_marks(input_stream::in, int::in, list(line_mark)::in,
    maybe_error(list(line_mark))::out, io::di, io::uo) is det.

read_line_marks(Stream, JavaLineNo, Marks0, MaybeMarks, !IO) :-
    read_line_as_string(Stream, Result, !IO),
    (
        Result = ok(Line),
        % The format string in mlds_to_java specifically uses spaces
        % rather than any other whitespace.
        Parts = string.split_at_char(' ', strip(Line)),
        (
            Parts = ["//", Marker, PathLine],
            (
                Marker = "MER_FOREIGN_BEGIN",
                Type = begin_block
            ;
                Marker = "MER_FOREIGN_END",
                Type = end_block
            ),
            PartsB = string.split_at_char(':', PathLine),
            PartsB = [MerFile, MerLineNoStr],
            string.to_int(MerLineNoStr, MerLineNo)
        ->
            Mark = line_mark(Type, MerFile, JavaLineNo, MerLineNo),
            Marks = [Mark | Marks0]
        ;
            Marks = Marks0
        ),
        read_line_marks(Stream, JavaLineNo+1, Marks, MaybeMarks, !IO)
    ;
        Result = eof,
        MaybeMarks = ok(Marks0)
    ;
        Result = error(Error),
        MaybeMarks = error(error_message(Error))
    ).

:- pred create_line_info(list(line_mark)::in, string::in,
    list(line_info)::in, maybe_error(list(line_info), line_info_error)::out)
    is det.

create_line_info([], _JavaFile, Infos, ok(InfosRev)) :-
    reverse(Infos, InfosRev).
create_line_info([Mark | Marks0], JavaFile, Infos0, MaybeInfos) :-
    Mark = line_mark(Type, MerFile, JavaLineNo, MerLineNo),
    (
        Type = begin_block,
        create_line_info_in_block(InfoEnd, Marks0, Marks),
        (
            InfoEnd = line_info_end(End),
            Delta = MerLineNo - JavaLineNo,
            Info = line_info(JavaLineNo, End, Delta, MerFile),
            Infos = [Info | Infos0],
            create_line_info(Marks, JavaFile, Infos, MaybeInfos)
        ;
            InfoEnd = line_info_no_end,
            MaybeInfos = error(line_info_error(JavaFile, JavaLineNo,
                lie_beginning_without_end))
        ;
            InfoEnd = line_info_duplicate_begin(SecondBeginLine),
            MaybeInfos = error(line_info_error(JavaFile, SecondBeginLine,
                lie_duplicate_beginning))
        )
    ;
        Type = end_block,
        MaybeInfos = error(line_info_error(JavaFile, JavaLineNo,
            lie_end_without_beginning))
    ).

:- type line_info_end
    --->    line_info_end(int)
    ;       line_info_no_end
    ;       line_info_duplicate_begin(int).

:- pred create_line_info_in_block(line_info_end::out,
    list(line_mark)::in, list(line_mark)::out) is det.

create_line_info_in_block(line_info_no_end, [], []).
create_line_info_in_block(Info, [Mark | Marks], Marks) :-
    Mark = line_mark(Type, _, End, _),
    (
        Type = begin_block,
        Info = line_info_duplicate_begin(End)
    ;
        Type = end_block,
        Info = line_info_end(End)
    ).

%-----------------------------------------------------------------------------%
:- end_module mfilterjavac.
%-----------------------------------------------------------------------------%