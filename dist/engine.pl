% The WebAssembly boot image already imports the JSON predicates.
:- use_module(library(sandbox)).
:- use_module(library(solution_sequences)).
:- use_module(library(lists)).
:- dynamic source_clause/3, source_rule/3, frame_node/2, trace_event/1, trace_boundary/1.
:- multifile user:prolog_trace_interception/4.
:- multifile sandbox:safe_primitive/1.
sandbox:safe_primitive(system:write(_)).
sandbox:safe_primitive(system:nl).

exercise:lab_execute(Goal) :- call(exercise:Goal).

% Backtrack over the hook: inspecting a frame must not bind user variables.
user:prolog_trace_interception(Port, Frame, _, continue) :-
    ( catch(record_port(Port, Frame), _, true), fail ; true ).

% Each browser worker owns its interpreter. Clear all prior user predicates
% before running another exercise so drafts cannot contaminate each other.
reset_program :-
    findall(PI, source_rule(PI,_,_), PIs), sort(PIs, Unique),
    forall(member(PI, Unique), catch(abolish(exercise:PI), _, true)).

run_json(JSON, Text) :-
    reset_program,
    catch((setup_call_cleanup(open_string(JSON, Stream),
             json_read_dict(Stream, Request), close(Stream)),
           run_request(Request, Result)), Error, error_result(Error, Result)),
    notrace,
    with_output_to(string(Text), json_write_dict(current_output, Result, [width(0)])).

error_result(Error, _{ok:false, error:Message, events:[], answers:[]}) :-
    notrace, message_to_string(Error, Message).

run_request(Request, Result) :-
    retractall(source_clause(_,_,_)), retractall(source_rule(_,_,_)), retractall(frame_node(_,_)),
    retractall(trace_event(_)), retractall(trace_boundary(_)),
    nb_setval(event_count, 0), nb_setval(node_count, 0),
    nb_setval(recording, false), nb_setval(trace_truncated, false),
    setup_call_cleanup(open_string(Request.code, Stream), load_source(Stream), close(Stream)),
    Query = Request.query,
    read_term_from_atom(Query, Goal, [variable_names(Names), module(exercise), syntax_errors(error)]),
    ( callable(Goal) -> true ; throw(error(type_error(callable, Goal), _)) ),
    sandbox:safe_goal(exercise:Goal), analyze_program(Analysis),
    Max is max(1, min(100, Request.get(maxAnswers, 20))),
    Inferences is max(1000, min(2000000, Request.get(inferences, 300000))),
    ( Request.get(trace, true) == true -> Trace = true ; Trace = false ),
    statistics(cputime, Start),
    with_output_to(string(Output),
      catch(collect(Goal, Names, Max, Inferences, Trace, Answers, Limited),
            Error, (notrace, nb_setval(recording,false), message_to_string(Error, Message)))),
    notrace, nb_setval(recording, false), statistics(cputime, End), Elapsed is End-Start,
    findall(E, trace_event(E), Events),
    nb_getval(trace_truncated, Truncated),
    ( nonvar(Message) ->
      Result = _{ok:false,error:Message,answers:[],events:Events,output:Output}
    ; Result = _{ok:true, answers:Answers, events:Events, output:Output,
                 limited:Limited, traceTruncated:Truncated, seconds:Elapsed,
                 engine:'SWI-Prolog', traced:Trace, analysis:Analysis} ).

load_source(Stream) :-
    read_term(Stream, Term, [module(exercise), syntax_errors(error), term_position(Position)]),
    stream_position_data(line_count, Position, Line),
    ( Term == end_of_file -> true
    ; install_term(Term, Line), load_source(Stream) ).

install_term((:- use_module(library(lists))), _) :- !,
    exercise:use_module(library(lists)).
install_term((:- use_module(library(apply))), _) :- !,
    exercise:use_module(library(apply)).
install_term((:- _), _) :- !,
    throw(error(permission_error(execute, directive, 'Solo se admite use_module de lists y apply'), _)).
install_term((Head :- Body), Line) :- !, install_clause(Head, Body, Line).
install_term(Head, Line) :- install_clause(Head, true, Line).

install_clause(Head, Body, Line) :-
    ( callable(Head), \+ Head = (_:_), \+ Head = (-->),
      functor(Head, Name, Arity), \+ sub_atom(Name, 0, 1, _, '$'),
      \+ predicate_property(exercise:Head, built_in),
      \+ predicate_property(exercise:Head, imported_from(_)) ->
      assertz(exercise:(Head :- Body), Ref),
      copy_term((Head :- Body), Copy), numbervars(Copy, 0, _),
      term_string(Copy, Text, [quoted(true), numbervars(true)]),
      assertz(source_clause(Ref, Line, Text)),
      assertz(source_rule(Name/Arity, Body, Line)),
      (Arity >= 0 -> true)
    ; throw(error(permission_error(define, predicate, Head), _)) ).

% A structural analysis of direct self calls, independent of the debugger.
% Calls inside meta-predicates and mutual recursion need a separate analysis.
analyze_program(Analysis) :-
    findall(PI, source_rule(PI,_,_), PIs), sort(PIs, Unique),
    findall(_{predicate:Name,recursive:Recursive,tail:Tail},
      (member(PI,Unique), term_string(PI,Name),
       findall(Flag,(source_rule(PI,Body,_),recursive_position(Body,PI,true,Flag)),Flags),
       (Flags == [] -> Recursive=false, Tail=false
       ; Recursive=true, (member(false,Flags) -> Tail=false ; Tail=true))), Analysis).

recursive_position(Goal,_,_,_) :- var(Goal), !, fail.
recursive_position((A,B),PI,Tail,Flag) :- !,
    (recursive_position(A,PI,false,Flag) ; recursive_position(B,PI,Tail,Flag)).
recursive_position((A;B),PI,Tail,Flag) :- !,
    (recursive_position(A,PI,Tail,Flag) ; recursive_position(B,PI,Tail,Flag)).
recursive_position((A->B),PI,Tail,Flag) :- !,
    (recursive_position(A,PI,false,Flag) ; recursive_position(B,PI,Tail,Flag)).
recursive_position(Goal,Name/Arity,Tail,Tail) :-
    callable(Goal), functor(Goal,Name,Arity).

collect(Goal, Names, Max, Inferences, Trace, Answers, Limited) :-
    Plus is Max + 1,
    ( Trace == true -> leash(-all), visible(+all), nb_setval(recording, true), trace ; true ),
    % WASM has no OS alarm. The UI terminates the worker after five seconds.
    call_with_inference_limit(
        findnsols(Plus, Answer, (exercise:lab_execute(Goal), answer_dict(Names, Answer)), Found),
        Inferences, Status),
    notrace, nb_setval(recording, false),
    ( Status == inference_limit_exceeded ->
      throw(error(resource_error(inference_limit), context(_, 'Se alcanzó el límite de inferencias. Revisá el caso base o reducí la entrada.')))
    ; length(Found, Count), (Count > Max -> length(Answers, Max), append(Answers, _, Found), Limited = true
                            ; Answers = Found, Limited = false) ).

answer_dict(Names, _{text:Text, bindings:Bindings}) :-
    copy_term(Names, Copy), numbervars(Copy, 0, _),
    findall(_{name:Name, value:Value},
      (member(Name=V, Copy), term_string(V, Value, [quoted(true), numbervars(true)])), Bindings),
    ( Bindings == [] -> Text = "true"
    ; findall(Part, (member(B, Bindings), format(string(Part), '~w = ~s', [B.name, B.value])), Parts),
      atomics_to_string(Parts, ', ', Text) ).

record_port(Port, Frame) :-
    nb_getval(recording, true),
    prolog_frame_attribute(Frame, goal, Qualified),
    strip_module(Qualified, _, Goal),
    (functor(Goal, lab_execute, 1) ->
       ((Port == call ; Port = redo(_)) -> retractall(trace_boundary(_)), assertz(trace_boundary(Frame)) ; true)
    ; inside_query(Frame), record_query_port(Port,Frame,Goal)).

inside_query(Frame) :-
    prolog_frame_attribute(Frame, parent, Parent),
    (trace_boundary(Parent), prolog_frame_attribute(Parent,goal,Q),
     strip_module(Q,_,G), functor(G,lab_execute,1) -> true
    ; inside_query(Parent)).

record_query_port(Port, Frame, Goal) :-
    nb_getval(event_count, Count),
    ( Count >= 2200 -> nb_setval(trace_truncated, true)
    ; normalize_port(Port, Kind),
      ( Kind == call ->
        nb_getval(node_count, Old), Id is Old + 1, nb_setval(node_count, Id),
        retractall(frame_node(Frame,_)), assertz(frame_node(Frame, Id))
      ; (frame_node(Frame, Id) -> true
        ; nb_getval(node_count, Old), Id is Old + 1, nb_setval(node_count, Id), assertz(frame_node(Frame,Id))) ),
      parent_node(Frame, Parent),
      copy_term(Goal, Copy), numbervars(Copy,0,_),
      term_string(Copy, Label, [quoted(true), numbervars(true), max_depth(18)]),
      (prolog_frame_attribute(Frame, clause, Ref), source_clause(Ref,Line,Clause) -> true ; Line=0, Clause=""),
      Next is Count+1, nb_setval(event_count, Next),
      assertz(trace_event(_{step:Next, port:Kind, id:Id, parent:Parent,
                           goal:Label, line:Line, clause:Clause})) ).

normalize_port(redo(_), redo) :- !.
normalize_port(exception(_), exception) :- !.
normalize_port(cut_call(_), cut) :- !.
normalize_port(cut_exit(_), cut_done) :- !.
normalize_port(Port, Port).

parent_node(Frame, Parent) :-
    ( prolog_frame_attribute(Frame, parent, P) ->
      (frame_node(P, Parent) -> true ; parent_node(P, Parent))
    ; Parent = 0 ).
