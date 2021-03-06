-module(character).
-export([init/1,
         cmsg_char_enum/3,
         cmsg_char_create/3]).

-include("realm_records.hrl").
-include("database_records.hrl").
-include("dbc_records.hrl").
-include("more_records.hrl").
-include("common.hrl").
-include("update.hrl").

-import(packet_helper, [make_cstring/1,
                        read_cstring/1]).
-import(common_helper, [do/1]).

%% @spec init(tuple()) -> ok.
init(State) ->
    not_in_world(State).

%% @spec not_in_world(tuple()) -> ok.
not_in_world(#client_state{receiver=R, sender=S}=State) ->
    receive
    {R, cmsg_realm_split, _} ->
        Date = list_to_binary("01/01/01"),
        S ! {self(), smsg_realm_split, <<16#FFFFFFFF?L, 0?L, Date/binary, 0?B>>},
        not_in_world(State);
    
    {R, cmsg_whois, _} ->
        Whois = account_helper:get_whois(State#client_state.account),
        S ! {self(), smsg_whois, <<Whois/bytes, 0?B>>},
        not_in_world(State);
    
    {R, cmsg_voice_session_enable, _} ->
        not_in_world(State);
    
    {R, msg_query_guild_bank_text, _} ->
        not_in_world(State);
    
    {R, cmsg_player_login, D} ->
        {ok, CharId} = realm_patterns:cmsg_player_login(D),
        Char = char_helper:find(CharId),
        ok = set_dungeon_difficulty(S, -1),
        CellPid = verify_world(S, Char),
        ok = send_account_data(S),
        ok = set_rest_start(S),
        ok = set_tutorial_flags(S),
        ok = send_spells_and_cooldowns(S),
        ok = send_action_buttons(S),
        ok = send_factions(S),
        ok = send_timespeed(S),
        ok = send_status(S),
        B = update_helper:block(create_object2, Char),
        P = update_helper:packet([B]),
        M = update_helper:message(P),
        S ! M,
        put(tick_count, 0),
        CellPid ! {add, self(), Char#char.position_x,
                                Char#char.position_y,
                                Char#char.position_z},
        CellPid ! {bco, self(), #vector{x=Char#char.position_x,
                                        y=Char#char.position_y,
                                        z=Char#char.position_z},
                                30,
                                {object_update, B}},
        io:format("~p sent update block: ~p~n", [self(), B]),
        in_world(State#client_state{current_map=CellPid, char=Char});

    {R, {M, F}, Data} ->
        C1 = erlang:module_loaded(M),
        C2 = erlang:function_exported(M, F, 3),
        if C1 and C2 ->
            NewState = M:F(S, State, Data),
            not_in_world(NewState);
        true ->
            io:format("undefined: ~p:~p(~p)~n", [M, F, Data]),
            not_in_world(State)
        end;
    
    {R, Handler, Data} ->
        io:format("unhandled: ~p(~p)~n", [Handler, Data]),
        not_in_world(State);
    
    Any ->
        io:format("unauthorized: ~p~n", [Any]),
        not_in_world(State)
    end.

%% @spec in_world(tuple()) -> ok.
in_world(#client_state{receiver=R, sender=S, char=Char}=State) ->
    receive   
    {R, cmsg_name_query, _} ->
        Response = <<(Char#char.id)?L, 0?L,
                     (make_cstring(Char#char.name))/binary,
                     0?B, 1?B, 1?B, 1?B, 0?B>>,
        S ! {self(), smsg_name_query_response, Response},
        in_world(State);
    
    {R, cmsg_update_account_data, _} ->
        in_world(State);
    
    {R, cmsg_set_active_mover, <<Mover?Q>>} ->
        put(active_mover, Mover),
        send_tick_count(S),
        in_world(State);
    
    {R, cmsg_set_actionbar_toggles, _} ->
        in_world(State);
    
    {R, cmsg_request_raid_info, _} ->
        S ! {self(), smsg_raid_instance_info, <<0?L>>},
        in_world(State);
    
    {R, cmsg_gmticket_getticket, _} ->
        S ! {self(), smsg_gmticket_getticket, <<10?L>>},
        in_world(State);
    
    {R, cmsg_query_time, _} ->
        UnixTime = common_helper:unix_time(),
        S ! {self(), smsg_query_time_response, <<UnixTime?L>>},
        in_world(State);
    
    {R, cmsg_item_query_single, _} ->
        in_world(State);

    {R, msg_query_next_mail_time, _} ->
        S ! {self(), msg_query_next_mail_time, <<16#C7A8C000?L, 0?L>>},
        in_world(State);

    {R, cmsg_battlefield_status, _} ->
        in_world(State);

    {R, cmsg_meetingstone_info, _} ->
        S ! {self(), smsg_meetingstone_setqueue, <<0?L, 6?B>>},
        in_world(State);

    {R, msg_guild_event_log_query, _} ->
        S ! {self(), msg_guild_event_log_query, <<0?B>>},
        in_world(State);

    {R, cmsg_move_time_skipped, _} ->
        in_world(State);

    {R, cmsg_tutorial_flag, _} ->
        in_world(State);
    
    {R, cmsg_time_sync_resp, <<Tick?L, Time?L>>} ->
        put(tick_count, Tick),
        put(client_time, Time),
        in_world(State);

    {R, {M, F}, Data} ->
        case M:F(S, State, Data) of
        {NewLoop, NewState} ->
            ?MODULE:NewLoop(NewState);
        NewState ->
            in_world(NewState)
        end;
    
    {R, Handler, Data} ->
        io:format("unhandled: ~p(~p)~n", [Handler, Data]),
        in_world(State);

    logout ->
        NewState = State#client_state{logout=no, current_map = -1, char=no},
        not_in_world(NewState);

    {object_update, B} ->
        io:format("~p got update block: ~p~n", [self(), B]),
        UF = B#update_block.update_flags,
        BB = B#update_block{ update_flags = lists:delete(self, UF) },
        P = update_helper:packet([BB]),
        M = update_helper:message(P),
        S ! M,
        in_world(State);

    {send, Opcode, Message} ->
        io:format("~p received forwarded packet: ~p~n", [self(), Opcode]),
        S ! {self(), Opcode, Message},
        in_world(State);

    send_create_to_cell ->
        B = update_helper:block(create_object2, Char),
        CellPid = State#client_state.current_map,
        CellPid ! {bco, self(), #vector{x=Char#char.position_x,
                                        y=Char#char.position_y,
                                        z=Char#char.position_z},
                                30,
                                {object_update, B}},
        in_world(State);

    die ->
        ok;

    Any ->
        io:format("unauthorized: ~p~n", [Any]),
        in_world(State)
    end.

%% @spec set_dungeon_difficulty(tuple(), int()) -> ok.
set_dungeon_difficulty(S, -1) ->
    S ! {self(), msg_set_dungeon_difficulty, <<0?L, 1?L, 0?L>>},
    ok;
set_dungeon_difficulty(S, Difficulty) ->
    S ! {self(), msg_set_dungeon_difficulty, <<Difficulty?L>>},
    ok.

%% @spec verify_world(pid(), tuple()) -> pid().
verify_world(S, Char) ->
    S ! { self(), smsg_login_verify_world, 
          <<(Char#char.map_id)?f, (Char#char.position_x)?f, 
            (Char#char.position_y)?f, (Char#char.position_z)?f,
            (Char#char.orientation)?f>> },
    world ! {self(), find, Char#char.map_id,
                           #vector{x=Char#char.position_x,
                                   y=Char#char.position_y,
                                   z=Char#char.position_z}},
    io:format("Waiting for cell pid~n"),
    receive 
    {world, found, CellPid} ->
        io:format("Received cell pid: ~p~n", [CellPid]),
        CellPid
    end.

%% @spec send_account_data(pid()) -> ok.
send_account_data(S) ->
    S ! {self(), smsg_account_data_times, <<0:1024>>},
    ok.

%% @spec set_rest_start(pid()) -> ok.
set_rest_start(S) ->
    GameTime = common_helper:game_time(),
    S ! {self(), smsg_set_rest_start, <<GameTime?L>>},
    ok.

%% @spec set_tutorial_flag(pid()) -> ok.
set_tutorial_flags(S) ->
    S ! {self(), smsg_tutorial_flags, <<0:256>>},
    ok.

%% @spec send_spells_and_cooldowns(pid()) -> ok.
send_spells_and_cooldowns(S) ->
    S ! {self(), smsg_initial_spells, <<0?B, 0?W, 0?W>>},
    ok.

%% @spec send_action_buttons(pid()) -> ok.
send_action_buttons(S) ->
    S ! {self(), smsg_action_buttons, <<>>},
    ok.

%% @spec send_factions(pid()) -> ok.
send_factions(S) ->
    S ! {self(), smsg_initialize_factions, <<128?L, 0:5120>>},
    ok.

%% @spec send_timespeed(pid()) -> ok.
send_timespeed(S) ->
    GameTime = common_helper:game_time(),
    S ! {self(), smsg_login_settimespeed, <<GameTime?L, (0.0166666669777748)?f>>},
    ok.

%% @spec send_status(pid()) -> ok.
send_status(S) ->
    S ! {self(), smsg_feature_system_status, <<2?B, 0?B>>},
    ok.

%% @spec send_tick_count(pid()) -> ok.
send_tick_count(S) ->
    S ! {self(), smsg_time_sync_req, <<(get(tick_count))?L>>},
    ok.

%% @spec cmsg_char_enum(pid(), tuple(), binary()) -> tuple().
cmsg_char_enum(S, St, _) ->
    Data = realm_patterns:smsg_char_enum(St#client_state.account, St#client_state.realm),
    S ! {self(), smsg_char_enum, Data},
    St.

%% @spec cmsg_char_create(pid(), tuple(), binary()) -> tuple().
cmsg_char_create(S, #client_state{account = Account, realm = Realm} = St, D) ->
    {Name, Rest} = read_cstring(D),
    <<Race?B, Class?B, Gender?B, Skin?B,
      Face?B, HS?B, HC?B, FH?B, _?B, _/binary>> = Rest,
    RaceName    = char_helper:to_race(Race),
    ClassName   = char_helper:to_class(Class),
    CreateInfo  = content:char_create_info(RaceName, ClassName),
    GenderValue = Gender * if Race =:= 10 -> -1; true -> 1 end,
    Char = #char{id               = random:uniform(16#FFFFFFFF),
                 account_id       = Account,
                 realm_id         = Realm,
                 name             = Name,
                 race             = RaceName, 
                 gender           = char_helper:to_gender(Gender),
                 class            = ClassName,
                 skin             = Skin, 
                 face             = Face, 
                 hair_style       = HS, 
                 hair_color       = HC,
                 facial_hair      = FH, 
                 level            = 1,
                 guild_id         = 0,
                 general_flags    = 16#10A00040,
                 at_login_flags   = 0,
                 faction_template = CreateInfo#char_create_info.faction_template, 
                 map_id           = CreateInfo#char_create_info.map_id, 
                 zone_id          = CreateInfo#char_create_info.zone_id, 
                 position_x       = CreateInfo#char_create_info.position_x, 
                 position_y       = CreateInfo#char_create_info.position_y, 
                 position_z       = CreateInfo#char_create_info.position_z, 
                 orientation      = CreateInfo#char_create_info.orientation, 
                 display_id       = CreateInfo#char_create_info.display_id + GenderValue, 
                 strength         = CreateInfo#char_create_info.strength, 
                 agility          = CreateInfo#char_create_info.agility,
                 stamina          = CreateInfo#char_create_info.stamina, 
                 intellect        = CreateInfo#char_create_info.intellect, 
                 spirit           = CreateInfo#char_create_info.spirit, 
                 health           = CreateInfo#char_create_info.health, 
                 mana             = CreateInfo#char_create_info.mana, 
                 focus            = CreateInfo#char_create_info.focus, 
                 power            = CreateInfo#char_create_info.power, 
                 power_type       = CreateInfo#char_create_info.power_type, 
                 intro            = CreateInfo#char_create_info.intro,
                 attack_power     = CreateInfo#char_create_info.attack_power, 
                 min_dmg          = CreateInfo#char_create_info.min_dmg, 
                 max_dmg          = CreateInfo#char_create_info.max_dmg, 
                 scale            = CreateInfo#char_create_info.scale},
    ok = mnesia:dirty_write(Char),
    S ! {self(), smsg_char_create, <<16#2f?B>>},
    St.
