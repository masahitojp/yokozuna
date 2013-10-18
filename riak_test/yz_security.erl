%% @doc Ensure that only approved users can search,index,schema
%%      if security is activated
-module(yz_security).
-compile(export_all).
-import(yz_rt, [host_entries/1,
                run_bb/2, search_expect/5,
                select_random/1, verify_count/2,
                write_terms/2]).
-import(rt, [connection_info/1,
             build_cluster/2, wait_for_cluster_service/2]).
-include("yokozuna.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(ROOT_CERT, "certs/selfsigned/ca/rootcert.pem").
-define(CFG(PrivDir),
        [{riak_core, [
           {ring_creation_size, 16},
           {default_bucket_props, [{allow_mult, true}]},
           {ssl, [
             {certfile, filename:join([PrivDir,
                                       "certs/selfsigned/site3-cert.pem"])},
             {keyfile, filename:join([PrivDir,
                                       "certs/selfsigned/site3-key.pem"])}
              ]},
           {security, true}
          ]},
         {riak_api, [
             {certfile, filename:join([PrivDir,
                                       "certs/selfsigned/site3-cert.pem"])},
             {keyfile, filename:join([PrivDir,
                                       "certs/selfsigned/site3-key.pem"])},
             {cacertfile, filename:join([PrivDir, ?ROOT_CERT])}
          ]},
         {yokozuna, [
           {enabled, true}
          ]}
        ]).
-define(SCHEMA_CONTENT, <<"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>
<schema name=\"test\" version=\"1.5\">
<fields>
   <field name=\"_yz_id\" type=\"_yz_str\" indexed=\"true\" stored=\"true\" required=\"true\" />
   <field name=\"_yz_ed\" type=\"_yz_str\" indexed=\"true\" stored=\"true\"/>
   <field name=\"_yz_pn\" type=\"_yz_str\" indexed=\"true\" stored=\"true\"/>
   <field name=\"_yz_fpn\" type=\"_yz_str\" indexed=\"true\" stored=\"true\"/>
   <field name=\"_yz_vtag\" type=\"_yz_str\" indexed=\"true\" stored=\"true\"/>
   <field name=\"_yz_node\" type=\"_yz_str\" indexed=\"true\" stored=\"true\"/>
   <field name=\"_yz_rk\" type=\"_yz_str\" indexed=\"true\" stored=\"true\"/>
   <field name=\"_yz_rb\" type=\"_yz_str\" indexed=\"true\" stored=\"true\"/>
</fields>
<uniqueKey>_yz_id</uniqueKey>
<types>
    <fieldType name=\"_yz_str\" class=\"solr.StrField\" sortMissingLast=\"true\" />
</types>
</schema>">>).
-define(USER, "user").
-define(PASSWORD, "password").
-define(INDEX, "myindex").
-define(INDEX_B, <<"myindex">>).
-define(INDEX2, "myindex2").
-define(INDEX2_B, <<"myindex2">>).
-define(SCHEMA, "myschema").
-define(SCHEMA_B, <<"myschema">>).
-define(BUCKET, "mybucket").
-define(ADD_USER(N,D), rpc:call(N, riak_core_console, add_user, D)).
-define(ADD_SOURCE(N,D), rpc:call(N, riak_core_console, add_source, D)).
-define(GRANT(N,D), rpc:call(N, riak_core_console, grant, D)).

confirm() ->
    application:start(crypto),
    application:start(asn1),
    application:start(public_key),
    application:start(ssl),
    application:start(ibrowse),
    PrivDir = rt_priv_dir(),
    lager:info("r_t priv: ~p", [PrivDir]),
    Cluster = build_cluster(1, ?CFG(PrivDir)),
    Node = hd(Cluster),
    enable_https(Node),
    wait_for_cluster_service(Cluster, yokozuna),
    create_user(Node),
    confirm_create_index_pb(Node),
    confirm_search_pb(Node),
    confirm_schema_permission_pb(Node),
    pass.

%% this is a similar duplicate riak_test fix as rt:priv_dir
%% otherwise rt:priv_dir() will point to yz's priv
rt_priv_dir() ->
    re:replace(code:priv_dir(riak_test),
        "riak_test(/riak_test)*", "riak_test", [{return, list}]).


enable_https(Node) ->
    {Host, Port} = proplists:get_value(http, connection_info(Node)),
    rt:update_app_config(Node, [{riak_api, [{https, [{Host, Port+1000}]}]}]),
    ok.

get_secure_pid(Host, Port) ->
    Cacertfile = filename:join([rt_priv_dir(), ?ROOT_CERT]),
    {ok, Pid} = riakc_pb_socket:start(Host, Port,
                                      [{credentials, ?USER, ?PASSWORD},
                                       {cacertfile, Cacertfile}]),
    Pid.

create_user(Node) ->
    {Host, Port} = proplists:get_value(pb, connection_info(Node)),

    {ok, PB0} =  riakc_pb_socket:start(Host, Port, []),
    ?assertEqual({error, <<"Security is enabled, please STARTTLS first">>},
                 riakc_pb_socket:ping(PB0)),

    lager:info("Adding a user"),
    ok = ?ADD_USER(Node, [[?USER, "password="++?PASSWORD]]),

    lager:info("Setting password mode on user"),
    ok = ?ADD_SOURCE(Node, [[?USER, Host++"/32", ?PASSWORD]]),

    Pid = get_secure_pid(Host, Port),
    ?assertEqual(pong, riakc_pb_socket:ping(Pid)),
    riakc_pb_socket:stop(Pid),
    ok.

confirm_create_index_pb(Node) ->
    {Host, Port} = proplists:get_value(pb, connection_info(Node)),

    Pid0 = get_secure_pid(Host, Port),
    lager:info("verifying user cannot create index without grants"),
    ?assertMatch({error, <<"Permission", _/binary>>},
        riakc_pb_socket:create_search_index(Pid0, ?INDEX_B)),

    lager:info("verifying user cannot list indexes without grants"),
    ?assertMatch({error, <<"Permission", _/binary>>},
        riakc_pb_socket:list_search_indexes(Pid0)),

    riakc_pb_socket:stop(Pid0),

    lager:info("Grant index permission to user"),
    ok = ?GRANT(Node, [["yokozuna.index","ON","index","TO",?USER]]),

    Pid1 = get_secure_pid(Host, Port),
    lager:info("verifying user can create an index"),
    ?assertEqual(ok,
        riakc_pb_socket:create_search_index(Pid1, ?INDEX_B)),
    yz_rt:set_index(Node, ?INDEX, ?BUCKET),
    yz_rt:wait_for_index([Node], ?INDEX),

    %% create another index, never give permission to use it
    ?assertEqual(ok,
        riakc_pb_socket:create_search_index(Pid1, ?INDEX2_B)),
    yz_rt:wait_for_index([Node], ?INDEX2),

    ?assertEqual(ok,
        riakc_pb_socket:create_search_index(Pid1, <<"_gonna_be_dead_">>)),
    yz_rt:wait_for_index([Node], "_gonna_be_dead_"),

    lager:info("verifying user can delete an index"),
    ?assertEqual(ok,
        riakc_pb_socket:delete_search_index(Pid1, <<"_gonna_be_dead_">>)),

    lager:info("verifying user can get an index"),
    ?assertMatch({ok,[_|_]},
        riakc_pb_socket:get_search_index(Pid1, ?INDEX_B)),

    lager:info("verifying user can get all indexes"),
    ?assertMatch({ok,[_|_]},
        riakc_pb_socket:list_search_indexes(Pid1)),
    riakc_pb_socket:stop(Pid1),
    ok.

confirm_schema_permission_pb(Node) ->
    {Host, Port} = proplists:get_value(pb, connection_info(Node)),

    Pid0 = get_secure_pid(Host, Port),
    lager:info("verifying user cannot create schema without grants"),
    ?assertMatch({error, <<"Permission", _/binary>>},
        riakc_pb_socket:create_search_schema(Pid0, ?SCHEMA_B, ?SCHEMA_CONTENT)),

    lager:info("verifying user cannot get schemas without grants"),
    ?assertMatch({error, <<"Permission", _/binary>>},
        riakc_pb_socket:get_search_schema(Pid0, ?SCHEMA_B)),
    riakc_pb_socket:stop(Pid0),

    lager:info("Grant schema permission to user"),
    ok = ?GRANT(Node, [["yokozuna.schema","ON","index","TO",?USER]]),

    Pid1 = get_secure_pid(Host, Port),
    lager:info("verifying user can create schema"),
    ?assertMatch(ok,
        riakc_pb_socket:create_search_schema(Pid1, ?SCHEMA_B, ?SCHEMA_CONTENT)),
    riakc_pb_socket:stop(Pid1),
    ok.

confirm_search_pb(Node) ->
    {Host, Port} = proplists:get_value(pb, connection_info(Node)),

    Pid0 = get_secure_pid(Host, Port),
    lager:info("verifying user cannot search an index without grants"),
    ?assertMatch({error, <<"Permission", _/binary>>},
        riakc_pb_socket:search(Pid0, ?INDEX_B, <<"*:*">>)),
    riakc_pb_socket:stop(Pid0),

    lager:info("Grant search permission to user on "++?INDEX),
    ok = ?GRANT(Node, [["yokozuna.search","ON","index",?INDEX,"TO",?USER]]),

    Pid1 = get_secure_pid(Host, Port),
    lager:info("verifying user can search granted on "++?INDEX),
    ?assertMatch({ok, _Result},
        riakc_pb_socket:search(Pid1, ?INDEX_B, <<"*:*">>)),

    lager:info("verifying user cannot search a different index"),
    ?assertMatch({error, <<"Permission", _/binary>>},
        riakc_pb_socket:search(Pid1, ?INDEX2_B, <<"*:*">>)),

    riakc_pb_socket:stop(Pid1),
    ok.