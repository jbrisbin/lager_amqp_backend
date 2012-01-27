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
-include_lib("lager/include/lager.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


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
  params,
  formatter,
  format_config,
  content_type
}).

init(Params) ->
  
  Name = config_val(name, Params, ?MODULE),  
  Level = config_val(level, Params, debug),
  Exchange = config_val(exchange, Params, list_to_binary(atom_to_list(?MODULE))),
  ContentType = config_val(content_type,Params,<<"text/plain">>),
  Formatter = config_val(formatter,Params,lager_default_formatter),
  FormatConfig = config_val(format_config,Params,[date, " ", time, " ", message]),
  
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
    params = AmqpParams,
	formatter = Formatter,
	format_config = FormatConfig,
	content_type=ContentType
  }}.

handle_call({set_loglevel, Level}, #state{ name = _Name } = State) ->
  % io:format("Changed loglevel of ~s to ~p~n", [Name, Level]),
  {ok, ok, State#state{ level=lager_util:level_to_num(Level) }};
    
handle_call(get_loglevel, #state{ level = Level } = State) ->
  {ok, Level, State};
    
handle_call(_Request, State) ->
  {ok, ok, State}.

handle_event(#lager_log_message{}=Msg, #state{ name = Name, level = L, params = AmqpParams } = State) ->
  case lager_backend_utils:is_loggable(Msg, L, {lager_amqp_backend, Name}) of
    true ->
      case amqp_channel(AmqpParams) of
        {ok, Channel} ->
          {ok, send(State, Msg, Channel)};
        _ -> 
          {ok, State}
      end;
    false ->
      {ok, State}
  end;

  
handle_event(_Event, State) ->
  {ok, State}.

handle_info(_Info, State) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
  
send(#state{ exchange = Exchange,formatter=Formatter } = State, #lager_log_message{severity_as_int=Level}=Message, Channel) ->

  RoutingKey = list_to_binary(atom_to_list(lager_util:num_to_level(Level))),
  Publish = #'basic.publish'{ exchange = Exchange, routing_key = RoutingKey },
  Props = #'P_basic'{ content_type = State#state.content_type },
  Body = iolist_to_binary(Formatter:format(Message,State#state.format_config)),
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
  % io:format("amqp params: ~p~n", [AmqpParams]),
  case pg2:get_closest_pid(AmqpParams) of
    {error, {no_such_group, _}} -> 
      pg2:create(AmqpParams),
      amqp_channel(AmqpParams);
    {error, {no_process, _}} -> 
      % io:format("no client running~n"),
      case amqp_connection:start(AmqpParams) of
        {ok, Client} ->
          % io:format("started new client: ~p~n", [Client]),
          case amqp_connection:open_channel(Client) of
            {ok, Channel} ->
              pg2:join(AmqpParams, Channel),
              {ok, Channel};
            {error, Reason} -> {error, Reason}
          end;
        {error, Reason} -> 
          % io:format("encountered an error: ~p~n", [Reason]),
          {error, Reason}
      end;
    Channel -> 
      % io:format("using existing channel: ~p~n", [Channel]),
      {ok, Channel}
  end.
  
test() ->
  application:load(lager),
  application:set_env(lager, handlers, [{lager_console_backend, debug}, {lager_amqp_backend, []}]),
  application:set_env(lager, error_logger_redirect, false),
  application:start(lager),
  lager:log(info, self(), "Test INFO message"),
  lager:log(debug, self(), "Test DEBUG message"),
  lager:log(error, self(), "Test ERROR message").

-ifdef(TEST).

-define(MESSAGE_TEXT,"Test Message").
-define(TEST_MESSAGE(Level,Destinations),
		#lager_log_message{
						   destinations=Destinations,
						   metadata=[],
						   severity_as_int=Level,
						   timestamp=lager_util:format_time(),
						   message= ?MESSAGE_TEXT}).

-define(TEST_STATE(Level),#state{name=name,format_config=[message],formatter=lager_default_formatter,level=Level,content_type= <<"text/plain">>}).
calls_syslog_test_() ->
	{foreach, fun() -> erlymock:start(),
					   erlymock:stub(pg2,get_closest_pid,['_'],[{return,channel_name}]),
					   erlymock:o_o(amqp_channel,cast,fun(channel_name,
													  #'basic.publish'{ routing_key = <<"info">> },
													  #amqp_msg{ payload = <<"Test Message">>}
														  ) -> true end
								    ),
					   erlymock:replay()
	 end,
	 fun(_) -> ok end,
	 [{"Test normal logging" ,
	   fun() ->
			   ?MODULE:handle_event(?TEST_MESSAGE(?INFO,[]), ?TEST_STATE(?INFO)),
			   % make sure that syslog:log was called with the test message
			   erlymock:verify()
	   end
	  },
	  {"Test logging by direct destination",
	   fun() ->
			   ?MODULE:handle_event(?TEST_MESSAGE(?INFO,[{?MODULE,name}]), ?TEST_STATE(?ERROR)),
			   % make sure that syslog:log was called with the test message
			   erlymock:verify()
	   end
	  }
	 ]}.

should_not_log_test_() ->
	{foreach, fun() -> erlymock:start(),
					   erlymock:stub(amqp_channel,cast,['_','_','_'], [{throw,should_not_be_called}]),
					   erlymock:replay()
	 end,
	 fun(_) -> ok end,
	 [{"Rejects based upon severity threshold" ,
	   fun() ->
			   ?MODULE:handle_event(?TEST_MESSAGE(?DEBUG,[]), ?TEST_STATE(?INFO)),
			   erlymock:verify()
	   end
	  }
	 ]}.

-endif.
