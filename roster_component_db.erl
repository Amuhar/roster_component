-module(roster_component_db).

-record(user_info, {jid, presence, uid, pwd}).

-record(reg_info, {jid, username, password}).

-export([init/0, set_subscription/1, get_subscription/1]).

-spec init() -> ok.
init() ->
	Node = node(),
	case mnesia:create_schema([Node]) of
		ok -> 
			mnesia:start(),
		    {atomic, ok} = 
		        mnesia:create_table(user_table, [{disc_copies, [node()]},
 				                    {type, set},
 				                    {attributes,record_info(fields, user_info)}]),
            mnesia:add_table_index(user_table, presence);
		_ -> 
			mnesia:start()
	end,
	ok.

set_subscription(RegInf) ->
    mnesia:dirty_write({user_table, RegInf#reg_info.jid, "online",
                        RegInf#reg_info.username, RegInf#reg_info.password}).


get_subscription(BareFrom) ->
   case mnesia:dirty_read({user_table, BareFrom}) of
       [] ->
	       notsubscribed;
       [{user_table, BareFrom, _Status, UId, Pwd}] ->
	       {subscribed, UId, Pwd}
   end.