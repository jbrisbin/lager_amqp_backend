%% Copyright (c) 2011 by Jon Brisbin. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

-module(lager_amqp_backend).
-behaviour(gen_event).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([
  init/1, 
  handle_call/2, 
  handle_event/2, 
  handle_info/2, 
  terminate/2,
  code_change/3,
  test/0
]).

-record(state, {
  name,
  level,
  exchange,
  params
}).

init(Params) ->
  
  Name = config_val(name, Params, ?MODULE),  
  Level = config_val(level, Params, debug),
  Exchange = config_val(exchange, Params, list_to_binary(atom_to_list(?MODULE))),
  
  AmqpParams = #amqp_params_network {
    username       = config_val(amqp_user, Params, <<"guest">>),
    password       = config_val(amqp_pass, Params, <<"guest">>),
    virtual_host   = config_val(amqp_vhost, Params, <<"/">>),
    host           = config_val(amqp_host, Params, "localhost"),
    port           = config_val(amqp_port, Params, 5672)
  },
  
  {ok, Channel} = amqp_channel(AmqpParams),
  #'exchange.declare_ok'{} = amqp_channel:call(Channel, #'exchange.declare'{ exchange = Exchange, type = <<"topic">> }),
  
  {ok, #state{ 
    name = Name, 
    level = Level, 
    exchange = Exchange,
    params = AmqpParams
  }}.

handle_call({set_loglevel, Level}, #state{ name = _Name } = State) ->
  % io:format("Changed loglevel of ~s to ~p~n", [Name, Level]),
  {ok, ok, State#state{ level=lager_util:level_to_num(Level) }};
    
handle_call(get_loglevel, #state{ level = Level } = State) ->
  {ok, Level, State};
    
handle_call(_Request, State) ->
  {ok, ok, State}.

handle_event({log, Dest, Level, {Date, Time}, Message}, #state{ name = Name, level = L} = State) when Level > L ->
  case lists:member({lager_amqp_backend, Name}, Dest) of
    true ->
      {ok, log(Level, Date, Time, Message, State)};
    false ->
      {ok, State}
  end;

handle_event({log, Level, {Date, Time}, Message}, #state{ level = L } = State) when Level =< L->
  {ok, log(Level, Date, Time, Message, State)};
  
handle_event(_Event, State) ->
  {ok, State}.

handle_info(_Info, State) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

log(Level, Date, Time, Message, #state{params = AmqpParams } = State) ->
  case amqp_channel(AmqpParams) of
    {ok, Channel} ->
      send(State, Level, [Date, " ", Time, " ", Message], Channel);
    _ ->
      State
  end.

send(#state{ name = Name, exchange = Exchange } = State, Level, Message, Channel) ->
  RkPrefix = atom_to_list(lager_util:num_to_level(Level)),
  RoutingKey =  list_to_binary( case Name of
                                  [] ->
                                    RkPrefix;
                                  Name ->
                                    string:join([RkPrefix, Name], ".")
                                end
                              ),
  Publish = #'basic.publish'{ exchange = Exchange, routing_key = RoutingKey },
  Props = #'P_basic'{ content_type = <<"text/plain">> },
  Body = list_to_binary(lists:flatten(Message)),
  Msg = #amqp_msg{ payload = Body, props = Props },

  % io:format("message: ~p~n", [Msg]),
  amqp_channel:cast(Channel, Publish, Msg),

  State.

config_val(C, Params, Default) ->
  case lists:keyfind(C, 1, Params) of
    {C, V} -> V;
    _ -> Default
  end.

amqp_channel(AmqpParams) ->
  case maybe_new_pid({AmqpParams, connection},
                     fun() -> amqp_connection:start(AmqpParams) end) of
    {ok, Client} ->
      maybe_new_pid({AmqpParams, channel},
                    fun() -> amqp_connection:open_channel(Client) end);
    Error ->
      Error
  end.

maybe_new_pid(Group, StartFun) ->
  case pg2:get_closest_pid(Group) of
    {error, {no_such_group, _}} ->
      pg2:create(Group),
      maybe_new_pid(Group, StartFun);
    {error, {no_process, _}} ->
      case StartFun() of
        {ok, Pid} ->
          pg2:join(Group, Pid),
          {ok, Pid};
        Error ->
          Error
      end;
    Pid ->
      {ok, Pid}
  end.
  
test() ->
  application:load(lager),
  application:set_env(lager, handlers, [{lager_console_backend, debug}, {lager_amqp_backend, []}]),
  application:set_env(lager, error_logger_redirect, false),
  application:start(lager),
  lager:log(info, self(), "Test INFO message"),
  lager:log(debug, self(), "Test DEBUG message"),
  lager:log(error, self(), "Test ERROR message").
  
