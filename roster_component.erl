-module(roster_component).

-export([start_link/0, stop/0, add_contact/4, subscribe_to_presence/3, 
         make_presence/3, make_forwarded_message/3, remove_contact/2,
         remove_item/3, make_message/4, send_message/2, get_user_roster/1]).

-export([init/1,handle_info/2, terminate/2, get_roster/0, handle_cast/2]).

-import (roster_component_db,[init/0, set_subscription/1, get_subscription/1]).

-include_lib("exmpp/include/exmpp_client.hrl").
-include_lib("exmpp/include/exmpp_nss.hrl").
-include_lib("exmpp/include/exmpp_xml.hrl").

-behaviour(gen_server).

-define(COMPONENT, "roster_access.localhost").
-define(SERVER_HOST, "localhost").
-define(SERVER_PORT, 8880).
-define(SECRET, "secret").

-define(NS_FORWARDED, <<"urn:xmpp:forward:0">>).
-define(NS_PRIVILEGE, <<"urn:xmpp:privilege:1">>).


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

%% roster set
add_contact(JidTo, Jid, Groups, Nick) ->
    gen_server:cast(?MODULE, {add_item, JidTo,Nick, Jid, Groups}).

remove_contact(JidTo, Jid) ->
    gen_server:cast(?MODULE, {remove_item, JidTo, Jid}).

send_message(From, To) ->
    gen_server:cast(?MODULE, {send_message, From, To}).

get_user_roster(User) ->
    gen_server:cast(?MODULE, {get, User}). 

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

handle_cast({get, User}, #state{session = Session} = State) ->
    RosterGet0 = get_roster(),
    RosterGet1 = exmpp_xml:set_attribute(RosterGet0,exmpp_xml:attribute(<<"to">>,User)),
    RosterGet2 = exmpp_xml:set_attribute(RosterGet1,exmpp_xml:attribute(<<"from">>,?COMPONENT)),
    exmpp_component:send_packet(Session, RosterGet2),
    {noreply, State};

handle_cast({send_message, From, To}, #state{session = Session} = State) ->
    Message0 = make_message(From, To,<<"chat">>, <<"Hi">>),
    Message = make_forwarded_message(?COMPONENT, <<"localhost">>, Message0),
    exmpp_component:send_packet(Session, Message),
    {noreply, State};

handle_cast({remove_item,JidTo,Jid}, #state{session = Session} = State) ->
    IQ0 = remove_item(Jid, [], <<"">>),
    IQ1 = exmpp_xml:set_attribute(IQ0,exmpp_xml:attribute(<<"to">>, JidTo)),
    IQ2 = exmpp_xml:set_attribute(IQ1,exmpp_xml:attribute(<<"from">>,?COMPONENT)),
    exmpp_component:send_packet(Session, IQ2),
    {noreply, State};

handle_cast({add_item,JidTo, Nick, Jid, Groups},  #state{session = Session} = State) ->
    IQ0 = set_item(Jid, Groups), %% we don't use Nick
    IQ1 = exmpp_xml:set_attribute(IQ0,exmpp_xml:attribute(<<"to">>, JidTo)),
    IQ2 = exmpp_xml:set_attribute(IQ1,exmpp_xml:attribute(<<"from">>,?COMPONENT)),
    exmpp_component:send_packet(Session, IQ2),
    %% send presence 
    SubscriptionRequest = subscribe_to_presence(JidTo,Jid, Nick),
    Presence = make_forwarded_message(?COMPONENT, <<"localhost">>, SubscriptionRequest),
    io:format("~s\n", [exmpp_xml:document_to_iolist(Presence)]),

    exmpp_component:send_packet(Session, Presence),
    {noreply, State}.

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
            process_received_presence(Session, Packet)
            
    end.

process_received_presence(Session, #received_packet{packet_type=presence,
                          type_attr=_Type, raw_packet=Presence}) ->
     io:format("~s\n", [exmpp_xml:document_to_iolist(Presence)]),
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
                         #received_packet{packet_type = message, raw_packet = Packet }) ->
    Childs = exmpp_xml:get_child_elements(Packet),
    case Childs of
        [#xmlel{name = "privilege"} = Child] ->
            process_message(Session, privilege, Packet);
        _ -> 
            process_message(Session, message, Packet)
    end.

%% TODO : add host and privilege access to state.
process_message(Session, privilege, Packet) ->
    io:format("~s\n", [exmpp_xml:document_to_iolist(Packet)]);

    

process_message(Session, message, Packet) ->
    io:format("~s\n", [exmpp_xml:document_to_iolist(Packet)]),
    %% retrieve recipient jid
    From = exmpp_xml:get_attribute(Packet, <<"from">>, <<"unknown">>),
    %% retrieve sender jid
    To = exmpp_xml:get_attribute(Packet, <<"to">>, <<"unknown">>),
    %% set recipient jid
    Pkt1 = exmpp_xml:set_attribute(Packet, <<"from">>, <<"roster_access2.localhost">>),
    %% set sender jid
    Pkt2 = exmpp_xml:set_attribute(Pkt1, <<"to">> , From),
    %% remove old id
    NewPacket = exmpp_xml:remove_attribute(Pkt2, <<"id">>),
    %% send new packet
    exmpp_session:send_packet(Session, NewPacket).

process_received_iq(Session,
            #received_packet{packet_type=iq, type_attr=Type, raw_packet=IQ}) ->
    case Type of 
        "result" -> 
            io:format("~s\n", [exmpp_xml:document_to_iolist(IQ)]);
        _ ->
            process_iq(Session,Type, exmpp_xml:get_ns_as_atom(exmpp_iq:get_payload(IQ)),IQ )
    end.

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
            RosterGet0 = get_roster(),
            RosterGet1 = exmpp_xml:set_attribute(RosterGet0,exmpp_xml:attribute(<<"to">>,Jid)),
            RosterGet2 = exmpp_xml:set_attribute(RosterGet1,exmpp_xml:attribute(<<"from">>,?COMPONENT)),
            exmpp_component:send_packet(Session, RosterGet2);
	     notsubscribed -> 
	         ok 
    end;

%% case of error
process_iq(Session, "error", NS, IQ) ->
    io:format("~s\n", [exmpp_xml:document_to_iolist(IQ)]);

process_iq(Session, Type, NS, IQ) ->
    %% set text value of IQ stanza
    io:format("~s\n", [exmpp_xml:document_to_iolist(IQ)]).
    % Reply = exmpp_xml:element(NS, 'response', [],
    %                                   [{xmlcdata,<<"your iq has been received">>}]),
    % %% build result packet
    % Result = exmpp_iq:result(IQ, exmpp_xml:element(NS, 'query', [], [Reply])),
    % %% sends new packet
    % exmpp_component:send_packet(Session, Result).

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

subscribe_to_presence(JID_FROM, JID_TO, Nick ) ->
    CompAddr = ?XMLCDATA(Nick),
    Presence = ?XMLEL4(?NS_USER_NICKNAME, 'nick', [], [CompAddr]),
    exmpp_xml:append_child(make_presence(JID_FROM,JID_TO, <<"subscribe">>), [Presence]).

make_presence(JID, Type) ->
    From = ?XMLATTR(<<"from">>, ?COMPONENT),
    PresenceType = ?XMLATTR(<<"type">>, Type),
    Presence = ?XMLEL4(?NS_COMPONENT_ACCEPT, 'presence', [PresenceType, From], []),
    exmpp_stanza:set_recipient(Presence, JID).

make_presence(JID_FROM, JID_TO, Type) ->
    From = ?XMLATTR(<<"from">>, JID_FROM),
    PresenceType = ?XMLATTR(<<"type">>, Type),
    Presence = ?XMLEL4(undefined, 'presence', [PresenceType, From], []),
    Presence0 = exmpp_stanza:set_recipient(Presence, JID_TO).

make_forwarded_message(JID_FROM, JID_TO, Child) ->
    From = ?XMLATTR(<<"from">>, JID_FROM),
    Id = ?XMLATTR(<<"id">>, component_id()),
    Message = ?XMLEL4(undefined, 'message', [Id, From], []),
    Message0 = exmpp_stanza:set_recipient(Message, JID_TO),
    %% privilege element
    Ns = ?XMLATTR(<<"xmlns">>, ?NS_PRIVILEGE ),
    Privilege = ?XMLEL4(undefined, 'privilege', [Ns],[]),
    %% forwarded element
    Ns0 = ?XMLATTR(<<"xmlns">>, ?NS_FORWARDED),
    Forwarded = ?XMLEL4(undefined, 'forwarded', [Ns0],[]),
    %% add stanza to forward
    Forwarded0 = exmpp_xml:append_child(Forwarded, Child),
    %% add forwarded to privilege
    Privilege0 = exmpp_xml:append_child(Privilege, Forwarded0),
    exmpp_xml:append_child(Message0,Privilege0).

make_message(From, To, Type, Content) ->
    Body = ?XMLCDATA(Content),
    Text = ?XMLEL4(undefined, 'body', [], [Body]),
    F = ?XMLATTR(<<"from">>, From),
    T = ?XMLATTR(<<"type">>, Type),
    Message0 = ?XMLEL4(undefined, 'message', [F,T], []),
    Message = exmpp_stanza:set_recipient(Message0, To),   
    exmpp_xml:append_child(Message, Text).

%%=============================================================================
%% From EXMPP exmpp_client_roster.erl
%%=============================================================================
component_id() ->
    "comp-" ++ integer_to_list(random:uniform(65536 * 65536)).


get_roster() ->
    get_roster(roster_id()).

get_roster(Id) ->
    Query = #xmlel{ns = ?NS_ROSTER, name = 'query'},
    Iq = exmpp_xml:set_attributes(
       #xmlel{ns = undefined, name = 'iq'},
       [{<<"type">>, "get"}, {<<"id">>, Id}]),
    exmpp_xml:append_child(Iq, Query).

roster_id() ->
    "rost-" ++ integer_to_list(random:uniform(65536 * 65536)).

set_item(ContactJID, Groups) ->
    set_item(roster_id(), ContactJID, Groups).

set_item(Id, ContactJID, Groups) ->
    Item = exmpp_xml:set_children(
        exmpp_xml:set_attributes(
             #xmlel{name = 'item'},
             [{<<"jid">>, ContactJID}]),
        [ exmpp_xml:set_cdata(
            exmpp_xml:element(?NS_ROSTER, 'group'),
            Gr) || Gr <- Groups]),
    Query = #xmlel{ns = ?NS_ROSTER, name = 'query'},
    Query2 = exmpp_xml:append_child(Query, Item),
    Iq = exmpp_xml:set_attributes(
       #xmlel{ns = undefined, name = 'iq'},
       [{<<"type">>, "set"}, {<<"id">>, Id}]),
    exmpp_xml:append_child(Iq, Query2).


remove_item(ContactJID, Groups, Nick) ->
    remove_item(roster_id(), ContactJID, Groups, Nick).

remove_item(Id, ContactJID, Groups, Nick) ->
    Item = exmpp_xml:set_children(
        exmpp_xml:set_attributes(
             #xmlel{name = 'item'},
             [{<<"jid">>, ContactJID}, 
              {<<"subscription">>, <<"remove">>}]),
        [ exmpp_xml:set_cdata(
            exmpp_xml:element(?NS_ROSTER, 'group'),
            Gr) || Gr <- Groups]),
    Query = #xmlel{ns = ?NS_ROSTER, name = 'query'},
    Query2 = exmpp_xml:append_child(Query, Item),
    Iq = exmpp_xml:set_attributes(
       #xmlel{ns = undefined, name = 'iq'},
       [{<<"type">>, "set"}, {<<"id">>, Id}]),
    exmpp_xml:append_child(Iq, Query2).