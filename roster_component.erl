-module(roster_component).

-export([start_link/0, stop/0]).

-export([init/1,handle_info/2, terminate/2]).

-import (roster_component_db,[init/0, set_subscription/1, get_subscription/1]).

-include_lib("exmpp/include/exmpp_client.hrl").
-include_lib("exmpp/include/exmpp_nss.hrl").
-include_lib("exmpp/include/exmpp_xml.hrl").

-behaviour(gen_server).

-define(COMPONENT, "roster_access.localhost").
-define(SERVER_HOST, "localhost").
-define(SERVER_PORT, 8888).
-define(SECRET, "secret").

-record(state, {session}).

-record(reg_info, {jid, username, password}).

%%=============================================================================
%% API
%%=============================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [],[]).

-spec stop() -> ok.
stop() ->
	gen_server:call(?MODULE, stop).

%% roster request

%%=============================================================================
%% callback functions
%%=============================================================================

-spec init([]) -> {ok, #state{}}.
init([]) ->
    exmpp:start(),
    roster_component_db:init(),
	Session = exmpp_component:start_link(),
	exmpp_component:auth(Session, ?COMPONENT, ?SECRET),
	_StreamId = exmpp_component:connect(Session, ?SERVER_HOST, ?SERVER_PORT),
	ok = exmpp_component:handshake(Session),
	{ok, #state{session = Session}}.

-spec handle_info(any(), #state{}) -> {noreply, #state{}}.
handle_info(#received_packet{} = Packet, #state{session = Session} = State) ->
    spawn(fun() -> process_received_packet(Session, Packet) end),
    {noreply, State}.

-spec terminate(any(), #state{}) -> any().
terminate(_Reason, _State) ->
	ok.

process_received_packet(Session, Packet) ->
    Packet_Type = Packet#received_packet.packet_type,
    case Packet_Type of
        iq ->
            process_received_iq(Session, Packet);
        message ->
            process_received_message(Session, Packet);
        presence ->
            process_received_presence(Session, Packet);
            K -> io:write(K)

    end.

process_received_presence(Session, #received_packet{packet_type=presence,
                          type_attr=_Type, raw_packet=Presence}) ->

     Status = exmpp_presence:get_show(Presence),
     From = exmpp_jid:parse(exmpp_stanza:get_sender(Presence)),
     BareFrom = binary_to_list(exmpp_jid:prep_bare_to_binary(From)),

     case get_subscription(BareFrom) of
	    {subscribed, UId, Pwd} ->
	        mnesia:dirty_write({user_table, BareFrom, Status, UId, Pwd});
	    _ ->
	        nothing
     end.


process_received_message(Session,
	               #received_packet{packet_type=message, raw_packet=Packet}) ->
    %% retrieve recipient jid
    From = exmpp_xml:get_attribute(Packet, <<"from">>, <<"unknown">>),
    %% retrieve sender jid
    To = exmpp_xml:get_attribute(Packet, <<"to">>, <<"unknown">>),
    %% set recipient jid
    Pkt1 = exmpp_xml:set_attribute(Packet, <<"from">>, To),
    %% set sender jid
    Pkt2 = exmpp_xml:set_attribute(Pkt1, <<"to">> , From),
    %% remove old id
    NewPacket = exmpp_xml:remove_attribute(Pkt2, <<"id">>),
    %% send new packet
    exmpp_session:send_packet(Session, NewPacket).

process_received_iq(Session,
            #received_packet{packet_type=iq, type_attr=Type, raw_packet=IQ}) ->
    process_iq(Session,Type, exmpp_xml:get_ns_as_atom(exmpp_iq:get_payload(IQ)),IQ ).

process_iq(Session, "get", ?NS_DISCO_INFO, IQ) ->
	Identity =  exmpp_xml:element(?NS_DISCO_INFO, 'identity', 
		            [exmpp_xml:attribute(<<"category">>, <<"component">>),
				     exmpp_xml:attribute(<<"type">>, <<"roster">>),
				     exmpp_xml:attribute(<<"name">>, <<"roster modification">>)], []),
	IQRegisterFeature = 
	    exmpp_xml:element(?NS_DISCO_INFO, 'feature', 
		                  [exmpp_xml:attribute(<<"var">>, ?NS_INBAND_REGISTER_s)],[]),
	
	Result = exmpp_iq:result(IQ, exmpp_xml:element(?NS_DISCO_INFO, 'query',[],
	                                          [Identity, IQRegisterFeature])),
	exmpp_component:send_packet(Session, Result);

process_iq(Session, "get", ?NS_INBAND_REGISTER, IQ) -> 
    From = exmpp_jid:parse(exmpp_stanza:get_sender(IQ)),
    BareFrom = binary_to_list(exmpp_jid:prep_bare_to_binary(From)),
   % io:format("~ts~n", [BareFrom]),
    case get_subscription(BareFrom) of
	    notsubscribed ->
	        send_registration_fields(Session, IQ, ?NS_INBAND_REGISTER);
	    {subscribed, UId, _Pwd} ->
	        send_registration_form(UId, Session, IQ)
    end;

%% TODO : password check

process_iq(Session, "set", ?NS_INBAND_REGISTER, IQ) ->
	From = exmpp_jid:parse(exmpp_stanza:get_sender(IQ)),
	Jid = binary_to_list(exmpp_jid:prep_bare_to_binary(From)),
	Elements = exmpp_xml:get_child_elements(exmpp_iq:get_payload(IQ)),
    RegistInfo = 
        lists:foldl(fun(#xmlel{ name = username, 
        	                    children = [#xmlcdata{ cdata = Data}] }, 
        	                    #reg_info{} = RegInf) ->
                                    RegInf#reg_info{username = Data};
                        (#xmlel{ name = password,
                                 children = [#xmlcdata{ cdata = Data}] },
                                 #reg_info{} = RegInf) ->
                                    RegInf#reg_info{password = Data} 
                    end, #reg_info{} ,Elements),
    RegInf = RegistInfo#reg_info{jid = Jid},
    ok = roster_component_db:set_subscription(RegInf),
	exmpp_component:send_packet(Session, exmpp_iq:result(IQ)),
    
    case get_subscription(Jid) of
	    {subscribed, UId, _Pwd}-> 
	        SubscriptionRequest = subscribe_to_presence(Jid),
            exmpp_component:send_packet(Session, SubscriptionRequest),
            RosterGet0 = exmpp_client_roster:get_roster(),
            RosterGet1 = exmpp_xml:set_attribute(RosterGet0,exmpp_xml:attribute(<<"to">>,Jid)),
            RosterGet2 = exmpp_xml:set_attribute(RosterGet1,exmpp_xml:attribute(<<"from">>,?COMPONENT)),
            exmpp_component:send_packet(Session, RosterGet2);
	     notsubscribed -> 
	         ok 
    end;

process_iq(Session, _Type, NS, IQ) ->
    %% set text value of IQ stanza
    Reply = exmpp_xml:element(NS, 'response', [],
                                      [{xmlcdata,<<"your iq has been received">>}]),
    %% build result packet
    Result = exmpp_iq:result(IQ, exmpp_xml:element(NS, 'query', [], [Reply])),
    %% sends new packet
    exmpp_component:send_packet(Session, Result).

send_registration_fields(Session, IQ, NS) ->
    Instructions = exmpp_xml:element(NS, 'instructions', [], [{xmlcdata,
                <<"Choose a username and password for use with this service.">>}]),
    Pwd = exmpp_xml:element(NS, 'password', [], []),
    User = exmpp_xml:element(NS, 'username', [], []),
    Result = exmpp_iq:result(IQ, exmpp_xml:element(NS, 'query', [],
                                        [Instructions, User, Pwd])),
    exmpp_component:send_packet(Session, Result).

send_registration_form(UId, Session, IQ) ->
    Registered = exmpp_xml:element(?NS_INBAND_REGISTER, 'registered', [], []),
    Username = exmpp_xml:element(?NS_INBAND_REGISTER, 'username', [],
				 [{xmlcdata, UId}]),
    Password = exmpp_xml:element(?NS_INBAND_REGISTER, 'password', [],
				 [{xmlcdata, ""}]),
    Result = exmpp_iq:result(IQ, exmpp_xml:element(?NS_INBAND_REGISTER,
                                         'query', [],
                                         [Registered, Username, Password])),
    exmpp_component:send_packet(Session, Result).


subscribe_to_presence(JID) ->
    CompAddr = ?XMLCDATA(<<>>),
    Presence = ?XMLEL4(?NS_USER_NICKNAME, 'nick', [], [CompAddr]),
    exmpp_xml:append_child(make_presence(JID, <<"subscribe">>), Presence).

make_presence(JID, Type) ->
    From = ?XMLATTR(<<"from">>, ?COMPONENT),
    PresenceType = ?XMLATTR(<<"type">>, Type),
    Presence = ?XMLEL4(?NS_COMPONENT_ACCEPT, 'presence', [PresenceType, From], []),
    exmpp_stanza:set_recipient(Presence, JID).