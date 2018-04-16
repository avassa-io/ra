-module(ra_log_memory).
-behaviour(ra_log).
-export([init/1,
         close/1,
         append/2,
         write/2,
         take/3,
         last_index_term/1,
         handle_event/2,
         last_written/1,
         fetch/2,
         fetch_term/2,
         flush/2,
         next_index/1,
         install_snapshot/2,
         read_snapshot/1,
         snapshot_index_term/1,
         update_release_cursor/4,
         read_meta/2,
         write_meta/3,
         sync_meta/1,
         can_write/1,
         overview/1,
         write_config/2,
         read_config/1,
         delete_everything/1,
         release_resources/1,
         to_list/1
        ]).

-include("ra.hrl").

-type ra_log_memory_meta() :: #{atom() => term()}.

-record(state, {last_index = 0 :: ra_index(),
                last_written = {0, 0} :: ra_idxterm(), % only here to fake the async api of the file based one
                entries = #{0 => {0, undefined}} :: #{ra_term() => {ra_index(), term()}},
                meta = #{} :: ra_log_memory_meta(),
                snapshot :: maybe(ra_log:ra_log_snapshot())}).

-type ra_log_memory_state() :: #state{}.

-spec init(_) -> ra_log_memory_state().
init(_Args) ->
    % initialized with a deafault 0 index 0 term dummy value
    % and an empty meta data map
    #state{}.

-spec close(ra_log_memory_state()) -> ok.
close(_State) ->
    % not much to do here
    ok.

-spec append(Entry::log_entry(), State::ra_log_memory_state()) ->
    {written, ra_log_memory_state()} | no_return().
append({Idx, Term, Data}, #state{last_index = LastIdx,
                                 entries = Log} = State)
  when Idx > LastIdx ->
    {written, State#state{last_index = Idx,
                          entries = Log#{Idx => {Term, Data}}}};
append(_Entry, _State) ->
    exit({integrity_error, undefined}).

-spec write(Entries :: [log_entry()], State::ra_log_memory_state()) ->
    {written, ra_log_memory_state()} |
    {error, {integrity_error, term()}}.
write([{FirstIdx, _, _} | _] = Entries,
      #state{last_index = LastIdx, entries = Log0} = State)
  when FirstIdx =< LastIdx + 1 ->
    % overwrite
    Log1 = case FirstIdx < LastIdx of
               true ->
                   maps:without(lists:seq(FirstIdx+1, LastIdx), Log0);
               false ->
                   Log0
           end,
    {Log, LastInIdx} = lists:foldl(fun ({Idx, Term, Data}, {Acc, _}) ->
                                           {Acc#{Idx => {Term, Data}}, Idx}
                                   end, {Log1, FirstIdx}, Entries),
    {written, State#state{last_index = LastInIdx,
                          entries = Log}};
write([{FirstIdx, _, _} | _] = Entries,
      #state{snapshot = Snapshot, entries = Log0} = State)
 when element(1, Snapshot) + 1 =:= FirstIdx ->
    {Log, LastInIdx} = lists:foldl(fun ({Idx, Term, Data}, {Acc, _}) ->
                                           {Acc#{Idx => {Term, Data}}, Idx}
                                   end, {Log0, FirstIdx}, Entries),
    {written, State#state{last_index = LastInIdx,
                          entries = Log}};
write(_Entries, _State) ->
    {error, {integrity_error, undefined}}.


-spec take(ra_index(), non_neg_integer(), ra_log_memory_state()) ->
    {[log_entry()], ra_log_memory_state()}.
take(Start, Num, #state{last_index = LastIdx, entries = Log} = State) ->
    {sparse_take(Start, Log, Num, LastIdx, []), State}.

% this allows for missing entries in the log
sparse_take(Idx, _Log, Num, Max, Res)
    when length(Res) =:= Num orelse
         Idx > Max ->
    lists:reverse(Res);
sparse_take(Idx, Log, Num, Max, Res) ->
    case Log of
        #{Idx := {T, D}} ->
            sparse_take(Idx+1, Log, Num, Max, [{Idx, T, D} | Res]);
        _ ->
            sparse_take(Idx+1, Log, Num, Max, Res)
    end.


-spec last_index_term(ra_log_memory_state()) -> maybe(ra_idxterm()).
last_index_term(#state{last_index = LastIdx,
                       entries = Log,
                       snapshot = Snapshot}) ->
    case Log of
        #{LastIdx := {LastTerm, _Data}} ->
            {LastIdx, LastTerm};
        _ ->
            % If not found fall back on snapshot if snapshot matches last term.
            case Snapshot of
                {LastIdx, LastTerm, _, _} ->
                    {LastIdx, LastTerm};
                _ ->
                    undefined
            end
    end.

-spec last_written(ra_log_memory_state()) -> ra_idxterm().
last_written(#state{last_written = LastWritten}) ->
    % we could just use the last index here but we need to "fake" it to
    % remain api compatible with  ra_log_file, for now at least.
    LastWritten.

-spec handle_event(ra_log:ra_log_event(), ra_log_memory_state()) ->
    ra_log_memory_state().
handle_event({written, {_From, Idx, Term}}, State0) ->
    case fetch_term(Idx, State0) of
        {Term, State} ->
            State#state{last_written = {Idx, Term}};
        _ ->
            % if the term doesn't match we just ignore it
            State0
    end.

-spec next_index(ra_log_memory_state()) -> ra_index().
next_index(#state{last_index = LastIdx}) ->
    LastIdx + 1.

-spec fetch(ra_index(), ra_log_memory_state()) ->
    {maybe(log_entry()), ra_log_memory_state()}.
fetch(Idx, #state{entries = Log} = State) ->
    case Log of
        #{Idx := {T, D}} ->
            {{Idx, T, D}, State};
        _ -> {undefined, State}
    end.

-spec fetch_term(ra_index(), ra_log_memory_state()) ->
    {maybe(ra_term()), ra_log_memory_state()}.
fetch_term(Idx, #state{entries = Log} = State) ->
    case Log of
        #{Idx := {T, _}} ->
            {T, State};
        _ -> {undefined, State}
    end.

flush(_Idx, Log) -> Log.

-spec install_snapshot(Snapshot :: ra_log:ra_log_snapshot(),
                     State :: ra_log_memory_state()) ->
    ra_log_memory_state().
install_snapshot(Snapshot, #state{entries = Log0} = State) ->
    Index  = element(1, Snapshot),
    % discard log
    Log = maps:filter(fun (K, _) -> K > Index end, Log0),
    State#state{entries = Log, snapshot = Snapshot}.

-spec read_snapshot(State :: ra_log_memory_state()) ->
    ra_log:ra_log_snapshot().
read_snapshot(#state{snapshot = Snapshot}) ->
    Snapshot.

-spec read_meta(Key :: ra_log:ra_meta_key(), State :: ra_log_memory_state()) ->
    maybe(term()).
read_meta(Key, #state{meta = Meta}) ->
    maps:get(Key, Meta, undefined).

-spec snapshot_index_term(State :: ra_log_memory_state()) ->
    ra_idxterm().
snapshot_index_term(#state{snapshot = {Idx, Term, _, _}}) ->
    {Idx, Term};
snapshot_index_term(#state{snapshot = undefined}) ->
    undefined.

-spec update_release_cursor(ra_index(), ra_cluster(), term(),
                            ra_log_memory_state()) ->
    ra_log_memory_state().
update_release_cursor(_Idx, _Cluster, _MacState, State) ->
    State.

-spec write_meta(Key :: ra_log:ra_meta_key(), Value :: term(),
                 State :: ra_log_memory_state()) ->
    {ok,  ra_log_memory_state()} | {error, term()}.
write_meta(Key, Value, #state{meta = Meta} = State) ->
    {ok, State#state{meta = Meta#{Key => Value}}}.

sync_meta(_Log) ->
    ok.

can_write(_Log) ->
    true.

overview(Log) ->
    #{type => ?MODULE,
      last_index => Log#state.last_index,
      last_written => Log#state.last_written,
      num_entries => maps:size(Log#state.entries)}.

write_config(_Config, _Log) ->
    ok.

read_config(_Log) ->
    not_found.

delete_everything(_Log) -> ok.

release_resources(State) ->
    State.

to_list(#state{entries = Log}) ->
    [{Idx, Term, Data} || {Idx, {Term, Data}} <- maps:to_list(Log)].

