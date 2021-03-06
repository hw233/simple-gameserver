%% 消息发送
-module(twins_server).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).
-compile(export_all).
-include("common.hrl").
-include("def_carlos.hrl").
-include("all_proto.hrl").
-include("data.hrl").
-include("record.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("def_mail.hrl").
-include("def_homestead.hrl").  
-define(DUMP_INTERVAL, (1000 * 60 * 10)).
-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------

start( ) ->
    {ok,_} = 
    supervisor:start_child(twins_sup,
                            {?MODULE,
                             {?MODULE, start_link,[]},
                             permanent, 600000, worker, [?MODULE]}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit,true),
        case db_sql:get_etc(?DB_ETC_KEY_TWINS) of
            [{CarlosWarInfo,CarlosRoleTimes}] ->
				lists:foreach(fun({K,V})-> ets:insert(?ETS_TWINS_ROLE_WAR,{K,V}) end, CarlosWarInfo),
				%%lists:foreach(fun({K,V})-> ets:insert(?ETS_TWINS_SIGN,{K,V}) end, CarlosSignInfo),
				% lists:foreach(fun({K,V})-> ets:insert(?ETS_TWINS_ROLETIMES,{K,V}) end, CarlosRoleTimes),
                %%在times结构中添加有效期的时间戳，减少ets表存储已经过期很久的玩家卡洛斯次数信息
                init_ets_twins_roletimes(CarlosRoleTimes);
            _ ->
               	ignore
        end,
    erlang:send_after(?DUMP_INTERVAL, erlang:self(), dump_data),
    %% 每天晚上12点统一刷新卡洛斯次数
	timer_wheel:init(),
    NextZeroClockSec = util:datetime_to_seconds({erlang:date(),{0,0,1}}) + ?ONE_DAY_SECONDS,
    timer_wheel:add_plan(NextZeroClockSec, fun hook_zero_clock/0),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
init_ets_twins_roletimes(CarlosRoleTimes)->
    NowSec = util:now(),
	lists:foreach(fun({K,V})->
        case V#tw_times.has_buy > 0 of
            true->
                case NowSec >= V#tw_times.valid_timestamp of
                    true->
                        FreeTimeLMT = data_twins:get(times_limit),
                        {BuyTimeLMT, _} = data_twins:get(buy_limit),
                        ets:insert(?ETS_TWINS_ROLETIMES,{K,V#tw_times{buy_left=BuyTimeLMT,free_left=FreeTimeLMT,valid_timestamp=get_twinstime_validtime()}});
                    false->
                        ets:insert(?ETS_TWINS_ROLETIMES,{K,V})
                end;
            false->
                case NowSec >= V#tw_times.valid_timestamp of
                    true->
                        ignore;
                    false->
                        ets:insert(?ETS_TWINS_ROLETIMES,{K,V})
                end
        end
	end, CarlosRoleTimes).


handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({Ref,_Res},State) when is_reference(Ref) ->
    {noreply,State};

handle_info({inet_reply,_S,_Status},State) ->
    {noreply,State};
    
handle_info(Info, State) ->
    case catch do_handle_info(Info, State) of
        {noreply, NewState} ->
            {noreply, NewState};
        Exeption ->
            ?ERR("Exeption:~w~n Info:~w~n State:~w~n", [Exeption, Info, State]),
            {noreply, State} 
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    do_persist(),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
do_handle_info({sign, RoleID, TeamID, TeamMember, Level}, State) ->
    ID = 
        case TeamID of
            -1 ->
                ?make_id(-RoleID, 1);
            _ ->
                ?make_id(TeamID, erlang:length(TeamMember))
        end,
    
	%% role_twins 会判断这些
	case ets:lookup(?ETS_TWINS_SIGN, {sign, ID}) of
		[_] ->
			ignore;
		_ ->
			ServerID = data_setting:get(server_id),
			{Info, IDList} = 
				case ID < 0 of
					true ->
                        #rolePublic{head=Head,isMale=IsMale,title=Title,level=Levle,fightPower=FightPower} = role_lib:get_rolePublic(RoleID),
                        {[#member_base_info{serverID=ServerID, roleID=RoleID, head=Head, isMale=IsMale, title=Title, level=Levle, fight_power=FightPower}], [RoleID]};
					_ ->
                        lists:foldl(fun(#p_team_member_info{roleID=MRoleID, head=Head, isMale=IsMale, title=Title, level=Levle, fightPower=FightPower}, {InfoAcc, IDAcc}) ->
                                        {[#member_base_info{serverID=ServerID, roleID=MRoleID, head=Head, isMale=IsMale, title=Title, level=Levle, fight_power=FightPower}|InfoAcc], [MRoleID|IDAcc]}
                                    end, {[], []}, TeamMember) 
				end,
            IsAfkPunish = lists:any(fun(RID)-> 
                            {S,_Timestamp} = afk_record_server:get_afk_punish(RID,?AFK_TYPE_TWINS),
                            2 =:= S
                end, IDList),
            case carlos_aux:check_team_sign_time(IDList) of
                false ->
                    sign_result(IDList, 11);
                _ when IsAfkPunish =:= true andalso TeamID =:= -1 ->
                    sign_result(IDList, 21);
                _ when IsAfkPunish =:= true andalso TeamID /= -1 ->
                    sign_result(IDList, 22);
                _ ->
			        Request = #tw_request{serverID=ServerID, id = ID, members=Info, level = Level},
			        ets:insert(?ETS_TWINS_SIGN, {{sign, ID}, IDList}),
			        twins_match:send_to_me({request, Request}),
                    behavior_carlos:log(IDList, ?carlos_type_twins, ?carlos_op_sign) 
            end
	end,
	{noreply, State};

%% 取消匹配
do_handle_info({unrequest, ID}, State) ->
        case ets:lookup(?ETS_TWINS_SIGN, {sign, ID}) of
        [] ->
            ignore;
        [{_, IDList}] ->
            ServerID = data_setting:get(server_id),
            twins_match:send_to_me({unrequest, ServerID, ID}),
            carlos_aux:set_team_unrequest_time(IDList),
            behavior_carlos:log(IDList, ?carlos_type_twins, ?carlos_op_unsign) 
    end,
    {noreply, State};

%% 成功取消匹配
do_handle_info({reply_unrequest, ID}, State) ->
    case ets:lookup(?ETS_TWINS_SIGN, {sign, ID}) of
        [] ->
            ignore;
        [{_, IDList}] ->
            ets:delete(?ETS_TWINS_SIGN, {sign, ID}),
            carlos_aux:set_team_unrequest_time(IDList),
            lists:foreach(fun(E) -> 
                            case role_lib:is_online(E) of
                                true ->
                                    %% 通知客户端取消匹配
                                    ?unicast(E, #sc_twins_unrequest{result=0});
                                _ ->
                                    ignore
                            end
                        end, IDList)
    end,
    {noreply, State};

%% 报名结果
do_handle_info({sign_result, ID, Result}, State) ->
    case ets:lookup(?ETS_TWINS_SIGN, {sign, ID}) of
        [] ->
            ignore;
        [{_, IDList}] ->
            case Result of
                0 ->
                    ignore;
                4 ->
                    ignore;
                _ ->
                    ets:delete(?ETS_TWINS_SIGN, {sign, ID}) 
            end,

	    case Result of 9 ->  ets:delete(?ETS_TWINS_SIGN, {sign, ID}); _ -> ignore end,
        sign_result(IDList, Result) 

    end,
   {noreply, State}; 

%% 匹配成功
do_handle_info({match_success, ID}, State) ->
    case ets:lookup(?ETS_TWINS_SIGN, {sign, ID}) of
        [] ->
            ignore;
        [{_, IDList}] ->
            lists:foreach(fun(MID) ->
                            CarlosTims = get_times(MID),
                            {NewLeft, NewMTimes} = deduct_times(CarlosTims), 
                            set_times(MID, NewMTimes), 
                            case role_lib:is_online(MID) of
                                true ->
                                    ?unicast(MID, #sc_twins_times_update{times=NewLeft});
                                _ ->
                                    ignore
                            end 
                        end, IDList),
            ets:delete(?ETS_TWINS_SIGN, {sign, ID}),
            behavior_carlos:log(IDList, ?carlos_type_twins, ?carlos_op_match_success) 
    end,
    {noreply, State};

do_handle_info({match_failed, ID}, State) ->
	case ets:lookup(?ETS_TWINS_SIGN, {sign,ID}) of
		[] ->
			ignore;
		[{_,IDList}] ->
			lists:foreach(fun(MID) ->
								  #tw_times{buy_left=BL,free_left=FL} = get_times(MID),
								  case role_lib:is_online(MID) of
									  true ->
										  ?unicast(MID,#sc_twins_sign{result=9,times=BL+FL});
									  _ ->
										  ignore
								  end
						  end,IDList),
			ets:delete(?ETS_TWINS_SIGN,{sign,ID})
	end,
	{noreply,State};
								  
								  

do_handle_info({get_player, RoleID, WarID,SID,P,Type},State) ->
	F = fun()->
				{FighterList,RoleLieuAdd,Talent,TrSpecial} = role_data:get_otherRoleFighter(RoleID),
				ItemList = role_data:get_otherRoleItemEquips(RoleID),
				RP = role_lib:get_rolePublic(RoleID),
				Fly = RP#rolePublic.plane_level,
				SkinInfo = role_data:get_otherRoleSkinInfo(RoleID),
                SpeedAdd = data_home:get({constr_type_plane_base,role_home:get_build_type_level(RoleID,?constr_type_plane_base)}),
				Msg = {Type,#tw_player{serverID=data_setting:get(server_id)
								   ,roleID=RoleID
								   ,roleName=RP#rolePublic.roleName
								   ,fighters=FighterList
								   ,baseFighters=FighterList
								   ,addBuff = RoleLieuAdd
								   ,talent=Talent
								   ,trSpecial=TrSpecial
								   ,itemList=ItemList
								   ,fly=Fly
								   ,speed=(get_fly_speed(Fly) * (10000 + SpeedAdd)) div 10000
								   ,level=RP#rolePublic.level
								   ,blood=100
                                   ,head = RP#rolePublic.head
                                   ,title = RP#rolePublic.title
                                   ,isMale = RP#rolePublic.isMale
                                   ,fight_power = RP#rolePublic.fightPower
									   ,skin_info = SkinInfo
									  ,grade=doublematch_server:dirty_get_role_dm_grade(RoleID)
								  }},
				send_msg:direct(SID,P,Msg),
				ets:insert(?ETS_TWINS_ROLE_WAR,{{match_info,RoleID},{WarID, SID,util:now()}}),
                behavior_carlos:log(RoleID, ?carlos_type_twins, ?carlos_op_enter_war, WarID),
				?CATCH(role_task:send_dispach(RoleID,{dispach_task,twins_fight,1})),
				ok
		end,
	spawn(F),
	{noreply,State};
do_handle_info({update_twins_war,RoleID,WarID}, State)->
	ets:delete(?ETS_TWINS_ROLE_WAR, {match_info,RoleID}),
    behavior_carlos:log(RoleID, ?carlos_type_twins, ?carlos_op_close_war, WarID),
	{noreply,State};
do_handle_info({twins_bc_info,RoleID,Info},State) ->
	?unicast(RoleID, Info),
	{noreply,State};
do_handle_info({inet_reply,_S,_Status},State) ->
    {noreply,State};

do_handle_info({fight_reward, RoleID, Reward},State) ->
	case role_lib:is_online(RoleID) of
		true ->
			role_lib:send_server(RoleID,{twins_reward,Reward});
		_ ->
			ignore
	end,
	{noreply,State};
do_handle_info({twins_reward,RoleID,TP,WinReward,Level,{T,Rank}},State) ->
    if
        TP =:= ?MAIL_TEMPLATE_TWINS_KICK ->
            afk_record_server:add_afk_record(RoleID,?AFK_TYPE_TWINS);
        TP =:= ?MAIL_TEMPLATE_TWINS_WIN->
            role_payGuide:asyn_trigger_task_change(RoleID,?TWINS_DIFFICULTY_N_WIN_N,{Level,1});
        true ->
            ignore
    end,
	mail_server:send_sys_mail(RoleID,TP,[Level],"",WinReward),
	?unicast(RoleID,#sc_twins_end_war{type=T,rank=Rank,level=Level}),
	{noreply,State};
do_handle_info({twins_box_reward,RoleID,R,Type,Level,Rank},State) ->
	TwinsRoleData = get_times(RoleID),
	TwinsRoleData2 = TwinsRoleData#tw_times{last_war_data={Level,R,Type}
										   ,rank_data=Rank
										   ,twins_box_data_list=[#p_twins_box_info{id=1,boxLevel=1,status=0}]
										   },
	set_times(RoleID,TwinsRoleData2),
	{noreply,State};

do_handle_info(clear_twins_buy_time,State)->
    case data_setting:get(server_type) of
        normal->
            spawn(fun()->clear_twins_buy_time() end);
        _ ->
            ignore
    end,
    {noreply,State};

%% 存盘
do_handle_info(dump_data, State) ->
    erlang:send_after(?DUMP_INTERVAL, erlang:self(), dump_data),
    do_persist(),
	ets_clean(),
    {noreply, State};

do_handle_info({timer_wheel_tick, LastTick}, State) ->
	timer_wheel:work(LastTick),
	{noreply, State};

do_handle_info(repair_refresh,State) ->
	repair_refresh(repair_refresh),
	{noreply,State};

%% do_handle_info({deduct_role_twinstime,RoleID,Msg},State)->
%%     deduct_twinstime(RoleID,Msg),
%%     {noreply,State};

do_handle_info(Info, State) ->
    ?ERR("未知的消息:~p.~n", [Info]),
    {noreply, State}.

ets_clean()->
	Time = data_twins:get(war_interval),
	MaxSec = util:now() - Time,
	Select = ets:fun2ms(fun({_,{_,_,S}}) when S =< MaxSec -> true end),
	F = fun()->
				ets:select_delete(?ETS_TWINS_ROLE_WAR,Select)
		end,
	spawn(F),
	ok.

do_persist() ->
	CarlosRoleWar = ets:tab2list(?ETS_TWINS_ROLE_WAR),
%	CarlosSignInfo = ets:tab2list(?ETS_TWINS_SIGN),
	CarlosRoleTimes = ets:tab2list(?ETS_TWINS_ROLETIMES),
    {CarlosRoleTimes2,DelCarlosRoleTimes} = delete_invalid_twins_role_time(CarlosRoleTimes),
    Info = [{CarlosRoleWar,CarlosRoleTimes2}],
    db_sql:set_etc(?DB_ETC_KEY_TWINS, Info),
    lists:foreach(fun(Obj)->ets:delete_object(?ETS_TWINS_ROLETIMES,Obj) end,DelCarlosRoleTimes).

delete_invalid_twins_role_time(CarlosRoleTimes)->
	lists:foldl(fun({_K,V}=Elem,{Acc,Del})->
						case util:now() > V#tw_times.valid_timestamp andalso V#tw_times.has_buy =< 0 of
							true->
								{Acc,[Elem|Del]};
							false->
								{[Elem|Acc],Del}
						end
			   end,{[],[]},CarlosRoleTimes).


send_twins_war_msg(Msg) ->
    erlang:send(?MODULE, Msg).

get_fly_speed(Type) ->
	Speed = data_carlos:get({speed, Type}),
	if is_integer(Speed) ->
		   Speed;
		true ->
			1
	end.

%% 获得卡洛斯次数
get_times(RoleID) ->
    case ets:lookup(?ETS_TWINS_ROLETIMES, {times, RoleID}) of
        [] ->
            FreeTimeLMT = data_twins:get(times_limit),
            {BuyTimeLMT, _} = data_twins:get(buy_limit),
            #tw_times{buy_left=BuyTimeLMT, free_left=FreeTimeLMT};
        [{_, Times}] ->
            Times
    end.

%% 设置卡洛斯次数
set_times(RoleID, Times) ->
    ets:insert(?ETS_TWINS_ROLETIMES, {{times, RoleID}, Times#tw_times{valid_timestamp=get_twinstime_validtime()}}).

%% 判断玩家个人是否保报了名
is_role_sign(RoleID) ->
    ID = ?make_id(-RoleID, 1),
    case ets:lookup(?ETS_TWINS_SIGN, {sign, ID}) of 
        [_] ->
            {true, ID};
        _ ->
            false
    end.

%% 判断队伍是否报名了
is_team_sign(TeamID, TeamLen) ->
    ID = ?make_id(TeamID, TeamLen),
    case ets:lookup(?ETS_TWINS_SIGN, {sign, ID}) of
        [_] ->
            {true, ID};
        _ ->
            false
    end.

%% 玩家是否在战场
is_role_in_war(RoleID) ->
    case ets:lookup(?ETS_TWINS_ROLE_WAR, {match_info, RoleID}) of
        [_] ->
            true;
        _ -> 
            false
    end.

%% 判断队伍是否在战场
is_team_in_war(TeamMember) ->
    lists:any(fun(#p_team_member_info{roleID=RoleID}) -> is_role_in_war(RoleID) end, TeamMember).

%% 扣除次数(传入的必须是有可用次数的)
deduct_times(#tw_times{has_buy=HasBuy, free_left=FreeLefts} = CarlosTimes) ->
    NewLeft = HasBuy + FreeLefts - 1,
    NewTimes = 
        case FreeLefts > 0 of
            true ->
                CarlosTimes#tw_times{free_left=FreeLefts - 1};
            _ ->
                CarlosTimes#tw_times{has_buy=HasBuy - 1}
        end,
    {NewLeft, NewTimes}.

hook_zero_clock() ->
    NextZeroClockSec = util:datetime_to_seconds({erlang:date(),{0,0,1}}) + ?ONE_DAY_SECONDS,
	timer_wheel:add_plan(NextZeroClockSec, fun hook_zero_clock/0),
	%% 刷新次数
	lists:foreach(fun({K, V}) ->
						  FreeTimeLMT = data_twins:get(times_limit),
						  {BuyTimeLMT, _} = data_twins:get(buy_limit),
						  ets:insert(?ETS_TWINS_ROLETIMES, {K, V#tw_times{buy_left=BuyTimeLMT
																		  ,free_left=FreeTimeLMT,has_buy=0}})
				  end, ets:tab2list(?ETS_TWINS_ROLETIMES)).


repair_refresh(repair_refresh) ->
	case util:now() < 1440129600 of
		true ->
			lists:foreach(fun({{timer_wheel_plan,_}=K,_}) -> erlang:erase(K);
							 (_) -> ignore
						  end, erlang:get()),
			timer_wheel:init(),
			hook_zero_clock(),
			ok;
		_ ->
			ignore
	end.

repair_refresh()->
	erlang:send(?MODULE,repair_refresh).

get_twinstime_validtime()->
    Day = erlang:date(),
    util:datetime_to_seconds({Day,{0,0,1}}) + ?ONE_DAY_SECONDS.

clear_twins_buy_time()->
    CarlosRoleTimes = ets:tab2list(?ETS_TWINS_ROLETIMES),
    NewCarlosRoleTimes = lists:foldl(fun({A,Times}=_Elem,Acc)->
        case Times#tw_times.has_buy =/= 0 of
            true->
                NewTimes = Times#tw_times{has_buy=0},
                [{A,NewTimes}|Acc];
            false->
                Acc
        end
    end,[],CarlosRoleTimes),
    ets:insert(?ETS_TWINS_ROLETIMES,NewCarlosRoleTimes).

sign_result(IDList, Result) ->
    lists:foreach(fun(MID) ->
                    #tw_times{has_buy=HasBuy, free_left=FreeLefts} = get_times(MID),
                    case role_lib:is_online(MID) of
                        true ->
                            ?unicast(MID, #sc_twins_sign{result=Result, times=HasBuy + FreeLefts});
                        _ ->
                            ignore
                    end 
                end, IDList).
