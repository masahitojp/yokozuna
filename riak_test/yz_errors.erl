%% @doc Ensure that error messages return as expected
-module(yz_errors).
-compile(export_all).
-import(yz_rt, [host_entries/1,
                run_bb/2, search_expect/5,
                select_random/1, verify_count/2,
                write_terms/2]).
-include("yokozuna.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(FMT(S, Args), lists:flatten(io_lib:format(S, Args))).
-define(NO_HEADERS, []).
-define(NO_BODY, <<>>).
-define(CFG,
        [{riak_core,
          [
           {handoff_concurrency, 16},
           {inactivity_timeout, 1000},
           {ring_creation_size, 16}
          ]},
         {yokozuna,
          [
	   {enabled, true}
          ]}
        ]).

confirm() ->
    random:seed(now()),
    Cluster = rt:build_cluster(4, ?CFG),
    rt:wait_for_cluster_service(Cluster, yokozuna),
    ok = test_errors(Cluster),
    pass.

test_errors(Cluster) ->
    ok = expect_bad_json(Cluster),
    ok = expect_bad_xml(Cluster),
    ok = expect_bad_query(Cluster),
    ok.

expect_bad_json(Cluster) ->
    Index = <<"bad_json">>,
    HP = yz_rt:select_random(host_entries(rt:connection_info(Cluster))),
    ok = create_index(Cluster, HP, Index),
    lager:info("Write bad json"),
    URL = bucket_url(HP, Index, "test"),
    Opts = [],
    CT = "application/json",
    Headers = [{"content-type", CT}],
    Body = "{\"bad\": \"unclosed\"",
    {ok, "204", _, _} = ibrowse:send_req(URL, Headers, put, Body, Opts),
    %% Sleep for soft commit
    timer:sleep(1100),
    %% still store the value in riak
    {ok, "200", _, Body} = ibrowse:send_req(URL, [{"accept", CT}], get, []),
    %% Sleep for soft commit
    timer:sleep(1100),
    ?assert(search_expect(HP, Index, ?YZ_ERR_FIELD_S, "1", 1)),
    ok.

expect_bad_xml(Cluster) ->
    Index = <<"bad_xml">>,
    HP = yz_rt:select_random(host_entries(rt:connection_info(Cluster))),
    ok = create_index(Cluster, HP, Index),
    lager:info("Write bad xml"),
    URL = bucket_url(HP, Index, "test"),
    Opts = [],
    CT = "application/xml",
    Headers = [{"content-type", CT}],
    Body = "<\"bad\" \"xml\"></",
    {ok, "204", _, _} = ibrowse:send_req(URL, Headers, put, Body, Opts),
    %% Sleep for soft commit
    timer:sleep(1100),
    %% still store the value in riak
    {ok, "200", _, Body} = ibrowse:send_req(URL, [{"accept", CT}], get, []),
    %% Sleep for soft commit
    timer:sleep(1100),
    ?assert(search_expect(HP, Index, ?YZ_ERR_FIELD_S, "1", 1)),
    ok.

expect_bad_query(Cluster) ->
    Index = <<"bad_query">>,
    HP = yz_rt:select_random(host_entries(rt:connection_info(Cluster))),
    ok = create_index(Cluster, HP, Index),
    lager:info("Write bad query"),
    URL = bucket_url(HP, Index, "test"),
    Opts = [],
    CT = "text/plain",
    Headers = [{"content-type", CT}],
    Body = "",
    {ok, "204", _, _} = ibrowse:send_req(URL, Headers, put, Body, Opts),
    %% Sleep for soft commit
    timer:sleep(1100),
    %% still store the value in riak
    {ok, "200", _, Body} = ibrowse:send_req(URL, [{"accept", CT}], get, []),
    %% send a bad query
    SearchURL = search_url(HP, Index) ++ "?q=*:*&sort=sco+desc",
    {ok, "400", _, _} = ibrowse:send_req(SearchURL, [], get, []),
    ok.

index_url({Host,Port}, Index) ->
    ?FMT("http://~s:~B/yz/index/~s", [Host, Port, Index]).

bucket_url({Host,Port}, Bucket, Key) ->
    ?FMT("http://~s:~B/buckets/~s/keys/~s", [Host, Port, Bucket, Key]).

search_url({Host,Port}, Bucket) ->
    ?FMT("http://~s:~B/search/~s", [Host, Port, Bucket]).

http(Method, URL, Headers, Body) ->
    Opts = [],
    ibrowse:send_req(URL, Headers, Method, Body, Opts).

create_index(Cluster, HP, Index) ->
    Node = yz_rt:select_random(Cluster),
    lager:info("create_index ~s [~p]", [Index, HP]),
    URL = index_url(HP, Index),
    Headers = [{"content-type", "application/json"}],
    {ok, Status, _, _} = http(put, URL, Headers, ?NO_BODY),
    yz_rt:set_index(Node, Index),
    yz_rt:wait_for_index(Cluster, Index),
    ?assertEqual("204", Status).
