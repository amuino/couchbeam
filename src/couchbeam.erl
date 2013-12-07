%%% -*- erlang -*-
%%%
%%% This file is part of couchbeam released under the MIT license.
%%% See the NOTICE for more information.

-module(couchbeam).
-author('Benoît Chesneau <benoitc@e-engura.org>').

-include("couchbeam.hrl").

-define(TIMEOUT, infinity).

% generic functions
-export([start/0, stop/0, version/0]).

%% utilities urls
-export([db_url/1, doc_url/2, server_url/1]).

%% API urls
-export([server_connection/0, server_connection/1,
         server_connection/2, server_connection/4,
         server_info/1,
         get_uuid/1, get_uuids/2,
         replicate/2, replicate/3, replicate/4,
         all_dbs/1, db_exists/2,
         create_db/2, create_db/3, create_db/4,
         open_db/2, open_db/3,
         open_or_create_db/2, open_or_create_db/3, open_or_create_db/4,
         delete_db/1, delete_db/2,
         db_info/1,
         save_doc/2, save_doc/3,
         doc_exists/2,
         open_doc/2, open_doc/3,
         delete_doc/2, delete_doc/3,
         save_docs/2, save_docs/3, delete_docs/2, delete_docs/3,
         lookup_doc_rev/2, lookup_doc_rev/3,
         fetch_attachment/3, fetch_attachment/4, stream_attachment/1,
         delete_attachment/3, delete_attachment/4,
         put_attachment/4, put_attachment/5, send_attachment/2,
         ensure_full_commit/1, ensure_full_commit/2,
         compact/1, compact/2]).


%% --------------------------------------------------------------------
%% Generic utilities.
%% --------------------------------------------------------------------

%% @doc Start the couchbeam process. Useful when testing using the shell.
start() ->
    couchbeam_deps:ensure(),
    application:load(couchbeam),
    couchbeam_util:start_app_deps(couchbeam),
    application:start(couchbeam).

%% @doc Stop the couchbeam process. Useful when testing using the shell.
stop() ->
    application:stop(couchbeam).

%% @spec () -> Version
%%     Version = string()
%% @doc Return the version of the application.
version() ->
    {ok, Version} = application:get_key(couchbeam, vsn),
    Version.

%% --------------------------------------------------------------------
%% API functins.
%% --------------------------------------------------------------------

%% @doc Create a server for connectiong to a CouchDB node
%% @equiv server_connection("127.0.0.1", 5984, "", [], false)
server_connection() ->
    #server{url = <<"http://127.0.0.1:5984">>,
            options = []}.

server_connection(URL) when is_list(URL) orelse is_binary(URL) ->
    #server{url=hackney_url:fix_path(URL), options=[]}.



%% @doc Create a server for connectiong to a CouchDB node
%% @equiv server_connection(Host, Port, "", [])

server_connection(URL, Options) when is_list(Options) ->
    #server{url=URL, options=[]};
server_connection(Host, Port) when is_integer(Port) ->
    server_connection(Host, Port, "", []).


%% @doc Create a server for connectiong to a CouchDB node
%%
%%      Connections are made to:
%%      ```http://Host:PortPrefix'''
%%
%%      If ssl is set https is used.
%%
%%      For a description of SSL Options, look in the <a href="http://www.erlang.org/doc/apps/ssl/index.html">ssl</a> manpage.
%%
%% @spec server_connection(Host::string(), Port::integer(),
%%                        Prefix::string(), Options::optionList())
%%                        -> Server::server()
%% optionList() = [option()]
%% option() =
%%          {is_ssl, boolean()}                |
%%          {ssl_options, [SSLOpt]}            |
%%          {pool_name, atom()}                |
%%          {proxy_host, string()}             |
%%          {proxy_port, integer()}            |
%%          {proxy_user, string()}             |
%%          {proxy_password, string()}         |
%%          {basic_auth, {username(), password()}} |
%%          {cookie, string()}                 |
%%          {oauth, oauthOptions()}
%%
%% username() = string()
%% password() = string()
%% SSLOpt = term()
%% oauthOptions() = [oauth()]
%% oauth() =
%%          {consumer_key, string()} |
%%          {token, string()} |
%%          {token_secret, string()} |
%%          {consumer_secret, string()} |
%%          {signature_method, string()}
%%
server_connection(Host, Port, Prefix, Options)
        when is_integer(Port), Port =:=443 ->
    BaseUrl = iolist_to_binary(["https://", Host, ":",
                                integer_to_list(Port)]),
    Url = hackney_url:make_url(BaseUrl, [Prefix], []),
    #server{url=Url, options=Options};
server_connection(Host, Port, Prefix, Options) ->
    BaseUrl = iolist_to_binary(["https://", Host, ":",
                                integer_to_list(Port)]),
    Url = hackney_url:make_url(BaseUrl, [Prefix], []),
    #server{url=Url, options=Options}.

%% @doc Get Information from the server
%% @spec server_info(server()) -> {ok, iolist()}
server_info(#server{url=Url, options=Opts}) ->
    case hackney:get(Url, [], <<>>, Opts) of
        {ok, 200, _, Ref} ->
            Version = couchbeam_httpc:json_body(Ref),
            {ok, Version};
        {ok, Status, Headers, Ref} ->
            {ok, Body} = hackney:body(Ref),
            {error, {bad_response, {Status, Headers, Body}}};

        Error ->
            Error
    end.

%% @doc Get one uuid from the server
%% @spec get_uuid(server()) -> lists()
get_uuid(Server) ->
    couchbeam_uuids:get_uuids(Server, 1).

%% @doc Get a list of uuids from the server
%% @spec get_uuids(server(), integer()) -> lists()
get_uuids(Server, Count) ->
    couchbeam_uuids:get_uuids(Server, Count).


%% @doc Handle replication. Pass an object containting all informations
%% It allows to pass for example an authentication info
%% ```
%% RepObj = {[
%% {<<"source">>, <<"sourcedb">>},
%% {<<"target">>, <<"targetdb">>},
%% {<<"create_target">>, true}
%% ]}
%% replicate(Server, RepObj).
%% '''
%%
%% @spec replicate(Server::server(), RepObj::{list()})
%%          -> {ok, Result}|{error, Error}
replicate(#server{url=ServerUrl, options=Opts}, RepObj) ->
    Url = hackney_url:make_url(ServerUrl, "_replicate", []),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    JsonObj = couchbeam_ejson:encode(RepObj),

     case couchbeam_httpc:request(post, Url, Headers, JsonObj, Opts) of
        {ok, Status, _, Ref} when Status =:= 200 orelse Status =:= 201 ->
            Res = couchbeam_httpc:json_body(Ref),
            {ok, Res};
        {ok, Status, Headers, Ref} ->
            {ok, Body} = hackney:body(Ref),
            {error, {bad_response, {Status, Headers, Body}}};
        Error ->
            Error
    end.

%% @doc Handle replication.
%% @spec replicate(Server::server(), Source::string(), Target::target())
%%          ->  {ok, Result}|{error, Error}
replicate(Server, Source, Target) ->
    replicate(Server, Source, Target, {[]}).

%% @doc handle Replication. Allows to pass options with source and
%% target.  Options is a Json object.
%% ex:
%% ```
%% Options = {[{<<"create_target">>, true}]},
%% couchbeam:replicate(S, "testdb", "testdb2", Options).
%% '''
replicate(Server, Source, Target, {Prop}) ->
    RepProp = [
        {<<"source">>, couchbeam_util:to_binary(Source)},
        {<<"target">>, couchbeam_util:to_binary(Target)} |Prop
    ],

    replicate(Server, {RepProp}).



%% @doc get list of databases on a CouchDB node
%% @spec all_dbs(server()) -> {ok, iolist()}
all_dbs(#server{url=ServerUrl, options=Opts}) ->
    Url = hackney_url:make_url(ServerUrl, <<"_all_dbs">>, []),
    Resp = couchbeam_httpc:db_request(get, Url, [], <<>>, Opts, [200]),
    case Resp of
        {ok, _, _, Ref} ->
            AllDbs = couchbeam_httpc:json_body(Ref),
            {ok, AllDbs};
        Error ->
            Error
    end.

%% @doc test if db with dbname exists on the CouchDB node
%% @spec db_exists(server(), string()) -> boolean()
db_exists(#server{url=ServerUrl, options=Opts}, DbName) ->
    Url = hackney_url:make_url(ServerUrl, dbname(DbName), []),
    case couchbeam_httpc:db_request(head, Url, [], <<>>, Opts, [200]) of
        {ok, _, _, Ref} ->
            hackney:skip_body(Ref),
            true;
        _Error ->
            false
    end.

%% @doc Create a database and a client for connectiong to it.
%% @equiv create_db(Server, DbName, [], [])
create_db(Server, DbName) ->
    create_db(Server, DbName, [], []).

%% @doc Create a database and a client for connectiong to it.
%% @equiv create_db(Server, DbName, Options, [])
create_db(Server, DbName, Options) ->
    create_db(Server, DbName, Options, []).

%% @doc Create a database and a client for connectiong to it.
%%
%%      Connections are made to:
%%      ```http://Host:PortPrefix/DbName'''
%%
%% If ssl is set https is used. See server_connections for options.
%% Params is a list of optionnal query argument you want to pass to the
%% db. Useful for bigcouch for example.
%%
%% @spec create_db(Server::server(), DbName::string(),
%%                 Options::optionList(), Params::list()) -> {ok, db()|{error, Error}}
create_db(#server{url=ServerUrl, options=Opts}=Server, DbName0, Options,
          Params) ->
    DbName = dbname(DbName0),
    Options1 = couchbeam_util:propmerge1(Options, Opts),
    Url = hackney_url:make_url(ServerUrl, DbName, Params),
    Resp = couchbeam_httpc:db_request(put, Url, [], <<>>, Options1, [201]),
    case Resp of
        {ok, _Status, _Headers, Ref} ->
            hackney:skip_body(Ref),
            {ok, #db{server=Server, name=DbName, options=Options1}};
        {error, precondition_failed} ->
            {error, db_exists};
       Error ->
          Error
    end.

%% @doc Create a client for connection to a database
%% @equiv open_db(Server, DbName, [])
open_db(Server, DbName) ->
    open_db(Server, DbName, []).

%% @doc Create a client for connection to a database
%% @spec open_db(Server::server(), DbName::string(), Options::optionList())
%%              -> {ok, db()}
open_db(#server{options=Opts}=Server, DbName, Options) ->
    Options1 = couchbeam_util:propmerge1(Options, Opts),
    {ok, #db{server=Server, name=dbname(DbName), options=Options1}}.


%% @doc Create a client for connecting to a database and create the
%%      database if needed.
%% @equiv open_or_create_db(Server, DbName, [], [])
open_or_create_db(Server, DbName) ->
    open_or_create_db(Server, DbName, [], []).

%% @doc Create a client for connecting to a database and create the
%%      database if needed.
%% @equiv open_or_create_db(Server, DbName, Options, [])
open_or_create_db(Server, DbName, Options) ->
    open_or_create_db(Server, DbName, Options, []).

%% @doc Create a client for connecting to a database and create the
%%      database if needed.
%% @spec open_or_create_db(server(), string(), list(), list()) -> {ok, db()|{error, Error}}
open_or_create_db(#server{url=ServerUrl, options=Opts}=Server, DbName0,
                  Options, Params) ->

    DbName = dbname(DbName0),
    Url = hackney_url:make_url(ServerUrl, DbName, []),
    Opts1 = couchbeam_util:propmerge1(Options, Opts),
    Resp = couchbeam_httpc:request(get, Url, [], <<>>, Opts1),
    case couchbeam_httpc:db_resp(Resp, [200]) of
        {ok, _Status, _Headers, Ref} ->
            hackney:skip_body(Ref),
            open_db(Server, DbName, Options);
        {error, {bad_response, {404, _, _}}} ->
            create_db(Server, DbName, Options, Params);
        Error ->
            Error
    end.

%% @doc delete database
%% @equiv delete_db(Server, DbName)
delete_db(#db{server=Server, name=DbName}) ->
    delete_db(Server, DbName).

%% @doc delete database
%% @spec delete_db(server(), DbName) -> {ok, iolist()|{error, Error}}
delete_db(#server{url=ServerUrl, options=Opts}, DbName) ->
    Url = hackney_url:make_url(ServerUrl, dbname(DbName), []),
    Resp = couchbeam_httpc:request(delete, Url, [], <<>>, Opts),
    case couchbeam_httpc:db_resp(Resp, [200]) of
        {ok, _, _, Ref} ->
            {ok, couchbeam_httpc:json_body(Ref)};
        Error ->
            Error
    end.

%% @doc get database info
%% @spec db_info(db()) -> {ok, iolist()|{error, Error}}
db_info(#db{server=Server, name=DbName, options=Opts}) ->
    Url = hackney_url:make_url(server_url(Server), dbname(DbName), []),
    case couchbeam_httpc:db_request(get, Url, [], <<>>, Opts, [200]) of
        {ok, _Status, _Headers, Ref} ->
            Infos = couchbeam_httpc:json_body(Ref),
            {ok, Infos};
        {error, {{bad_response, {404, _, _}}}} ->
            {error, db_not_found};
       Error ->
          Error
    end.

%% @doc test if doc with uuid exists in the given db
%% @spec doc_exists(db(), string()) -> boolean()
doc_exists(#db{server=Server, options=Opts}=Db, DocId) ->
    DocId1 = couchbeam_util:encode_docid(DocId),
    Url = hackney_url:make_url(server_url(Server), doc_url(Db, DocId1), []),
    case couchbeam_httpc:db_request(head, Url, [], <<>>, Opts, [200]) of
        {ok, _, _, Ref} ->
            hackney:skip_body(Ref),
            true;
        _Error -> false
    end.

%% @doc open a document
%% @equiv open_doc(Db, DocId, [])
open_doc(Db, DocId) ->
    open_doc(Db, DocId, []).

%% @doc open a document
%% Params is a list of query argument. Have a look in CouchDb API
%% @spec open_doc(Db::db(), DocId::string(), Params::list())
%%          -> {ok, Doc}|{error, Error}
open_doc(#db{server=Server, options=Opts}=Db, DocId, Params) ->
    DocId1 = couchbeam_util:encode_docid(DocId),
    Url = hackney_url:make_url(server_url(Server), doc_url(Db, DocId1),
                               Params),
    case couchbeam_httpc:db_request(get, Url, [], <<>>, Opts, [200, 201]) of
        {ok, _, _, Ref} ->
            {ok, couchbeam_httpc:json_body(Ref)};
        Error ->
            Error
    end.

%% @doc save a document
%% @equiv save_doc(Db, Doc, [])
save_doc(Db, Doc) ->
    save_doc(Db, Doc, []).

%% @doc save a document
%% A document is a Json object like this one:
%%
%%      ```{[
%%          {<<"_id">>, <<"myid">>},
%%          {<<"title">>, <<"test">>}
%%      ]}'''
%%
%% Options are arguments passed to the request. This function return a
%% new document with last revision and a docid. If _id isn't specified in
%% document it will be created. Id is created by extracting an uuid from
%% the couchdb node.
%%
%% @spec save_doc(Db::db(), Doc, Options::list()) -> {ok, Doc1}|{error, Error}
save_doc(#db{server=Server, options=Opts}=Db, {Props}=Doc, Options) ->
    DocId = case couchbeam_util:get_value(<<"_id">>, Props) of
        undefined ->
            [Id] = get_uuid(Server),
            Id;
        DocId1 ->
            couchbeam_util:encode_docid(DocId1)
    end,
    Url = hackney_url:make_url(server_url(Server), doc_url(Db, DocId),
                               Options),
    io:format("url = ~p~n", [Url]),
    Body = couchbeam_ejson:encode(Doc),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],

    case couchbeam_httpc:db_request(put, Url, Headers, Body, Opts,
                                    [200, 201]) of
        {ok, _, _, Ref} ->
            {JsonProp} = couchbeam_httpc:json_body(Ref),
            NewRev = couchbeam_util:get_value(<<"rev">>, JsonProp),
            NewDocId = couchbeam_util:get_value(<<"id">>, JsonProp),
            Doc1 = couchbeam_doc:set_value(<<"_rev">>, NewRev,
                couchbeam_doc:set_value(<<"_id">>, NewDocId, Doc)),
            {ok, Doc1};
        Error ->
            Error
    end.

%% @doc delete a document
%% @equiv delete_doc(Db, Doc, [])
delete_doc(Db, Doc) ->
    delete_doc(Db, Doc, []).

%% @doc delete a document
%% if you want to make sure the doc it emptied on delete, use the option
%% {empty_on_delete,  true} or pass a doc with just _id and _rev
%% members.
%% @spec delete_doc(Db, Doc, Options) -> {ok,Result}|{error,Error}
delete_doc(Db, Doc, Options) ->
     delete_docs(Db, [Doc], Options).

%% @doc delete a list of documents
%% @equiv delete_docs(Db, Docs, [])
delete_docs(Db, Docs) ->
    delete_docs(Db, Docs, []).

%% @doc delete a list of documents
%% if you want to make sure the doc it emptied on delete, use the option
%% {empty_on_delete,  true} or pass a doc with just _id and _rev
%% members.
%% @spec delete_docs(Db::db(), Docs::list(),Options::list()) -> {ok, Result}|{error, Error}
delete_docs(Db, Docs, Options) ->
    Empty = couchbeam_util:get_value("empty_on_delete", Options, false),

    {FinalDocs, FinalOptions} = case Empty of
        true ->
            Docs1 = lists:map(fun(Doc)->
                        {[{<<"_id">>, couchbeam_doc:get_id(Doc)},
                         {<<"_rev">>, couchbeam_doc:get_rev(Doc)},
                         {<<"_deleted">>, true}]}
                 end, Docs),
             {Docs1, proplists:delete("all_or_nothing", Options)};
         _ ->
            Docs1 = lists:map(fun({DocProps})->
                        {[{<<"_deleted">>, true}|DocProps]}
                end, Docs),
            {Docs1, Options}
    end,
    save_docs(Db, FinalDocs, FinalOptions).

%% @doc save a list of documents
%% @equiv save_docs(Db, Docs, [])
save_docs(Db, Docs) ->
    save_docs(Db, Docs, []).

%% @doc save a list of documents
%% @spec save_docs(Db::db(), Docs::list(),Options::list()) -> {ok, Result}|{error, Error}
save_docs(#db{server=Server, options=Opts}=Db, Docs, Options) ->
    Docs1 = [maybe_docid(Server, Doc) || Doc <- Docs],
    Options1 = couchbeam_util:parse_options(Options),
    {Options2, Body} = case couchbeam_util:get_value("all_or_nothing",
            Options1, false) of
        true ->
            Body1 = couchbeam_ejson:encode({[
                {<<"all_or_nothing">>, true},
                {<<"docs">>, Docs1}
            ]}),

            {proplists:delete("all_or_nothing", Options1), Body1};
        _ ->
            Body1 = couchbeam_ejson:encode({[{<<"docs">>, Docs1}]}),
            {Options1, Body1}
        end,
    Url = hackney_url:make_url(server_url(Server),
                               [db_url(Db), <<"_bulk_docs">>],
                               Options2),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case couchbeam_httpc:db_request(post, Url, Headers, Body, Opts, [201]) of
        {ok, _, _, Ref} ->
            {ok, couchbeam_httpc:json_body(Ref)};
        Error ->
            Error
        end.

lookup_doc_rev(Db, DocId) ->
    lookup_doc_rev(Db, DocId, []).

lookup_doc_rev(#db{server=Server, options=Opts}=Db, DocId, Params) ->
    DocId1 = couchbeam_util:encode_docid(DocId),
    Url = hackney_url:make_url(server_url(Server), doc_url(Db, DocId1),
                               Params),
    case couchbeam_httpc:db_request(head, Url, [], <<>>, Opts, [200]) of
        {ok, _, Headers, _} ->
            HeadersDict = hackney_headers:new(Headers),
            re:replace(hackney_headers:get_value(<<"etag">>, HeadersDict),
                <<"\"">>, <<>>, [global, {return, binary}]);
        Error ->
            Error
    end.

%% @doc fetch a document attachment
%% @equiv fetch_attachment(Db, DocId, Name, [])
fetch_attachment(Db, DocId, Name) ->
    fetch_attachment(Db, DocId, Name, []).

%% @doc fetch a document attachment
%% Options are
%% <ul>
%% <li>`stream': to start streaming an attachment. the function return
%% `{ok, Ref}' where is a ref to the attachment</li>
%% <li>Other options that can be sent using the REST API</li>
%% </ul>
%%
-spec fetch_attachment(db(), string(), string(),
                       list())
    -> {ok, binary()}| {ok, atom()} |{error, term()}.
fetch_attachment(#db{server=Server, options=Opts}=Db, DocId, Name, Options0) ->
    {Stream, Options} = case couchbeam_util:get_value(stream, Options0) of
        undefined ->
            {false, Options0};
        true ->
            {true, proplists:delete(stream, Options0)};
        _ ->
            {false, proplists:delete(stream, Options0)}
    end,


    Options1 = couchbeam_util:parse_options(Options),

    %% custom headers. Allows us to manage Range.
    {Options2, Headers} = case couchbeam_util:get_value("headers", Options1) of
        undefined ->
            {Options1, []};
        Headers1 ->
            {proplists:delete("headers", Options1), Headers1}
    end,

    DocId1 = couchbeam_util:encode_docid(DocId),
    Url = hackney_url:make_url(server_url(Server),
                               [db_url(Db), DocId1,
                                Name],
                               Options2),
    case hackney:get(Url, Headers, <<>>, Opts) of
        {ok, 200, _, Ref} when Stream /= true ->
            hackney:body(Ref);
        {ok, 200, _, Ref} ->
            {ok, Ref};
        {ok, 404, _, Ref} ->
            hackney:skip_body(Ref),
            {error, not_found};
        {ok, Status, Headers, Ref} ->
            {ok, Body} = hackney:body(Ref),
            {error, {bad_response, {Status, Headers, Body}}};

        Error ->
            Error
    end.

%% @doc fetch an attachment chunk.
%% Use this function when you pass the `stream' option to the
%% `couchbeam:fetch_attachment/4' function.
%% This function return the following response:
%%      <dl>
%%          <dt>done</dt>
%%              <dd>You got all the attachment</dd>
%%          <dt>{ok, binary()}</dt>
%%              <dd>Part of the attachment</dd>
%%          <dt>{error, term()}</dt>
%%              <dd>n error occurred</dd>
%%      </dl>
%%

-spec stream_attachment(atom()) -> {ok, binary()}
    | done
    | {error, term()}.
stream_attachment(Ref) ->
    hackney:stream_body(Ref).

%% @doc put an attachment
%% @equiv put_attachment(Db, DocId, Name, Body, [])
put_attachment(Db, DocId, Name, Body)->
    put_attachment(Db, DocId, Name, Body, []).

%% @doc put an attachment
%% @spec put_attachment(Db::db(), DocId::string(), Name::string(),
%%                      Body::body(), Option::optionList()) -> {ok, iolist()}
%%       optionList() = [option()]
%%       option() = {rev, string()} |
%%                  {content_type, string()} |
%%                  {content_length, string()}
%%       body() = [] | string() | binary() | fun_arity_0() |
%%       {fun_arity_1(), initial_state(), stream}
%%       initial_state() = term()
put_attachment(#db{server=Server, options=Opts}=Db, DocId, Name, Body,
               Options) ->
    QueryArgs = case couchbeam_util:get_value(rev, Options) of
        undefined -> [];
        Rev -> [{<<"rev">>, couchbeam_util:to_binary(Rev)}]
    end,

    Headers = couchbeam_util:get_value(headers, Options, []),


    FinalHeaders = lists:foldl(fun(Option, Acc) ->
                case Option of
                        {content_length, V} ->
                            V1 = couchbeam_util:to_binary(V),
                            [{<<"Content-Length">>, V1}|Acc];
                        {content_type, V} ->
                            V1 = couchbeam_util:to_binary(V),
                            [{<<"Content-Type">>, V1}|Acc];
                        _ ->
                            Acc
                end
        end, Headers, Options),

    DocId1 = couchbeam_util:encode_docid(DocId),
    AttName = couchbeam_util:encode_att_name(Name),
    Url = hackney_url:make_url(server_url(Server), [db_url(Db), DocId1,
                                                    AttName],
                               QueryArgs),

    case couchbeam_httpc:db_request(put, Url, FinalHeaders, Body, Opts,
                                   [201]) of
        {ok, _, _, Ref} ->
            {[{<<"ok">>, true}|R]} = couchbeam_httpc:json_body(Ref),
            {ok, {R}};
        {ok, Ref} ->
            {ok, Ref};
        Error ->
            Error
    end.

%% @doc send an attachment chunk
%% Msg could be Data, eof to stop sending.
send_attachment(Ref, eof) ->
    case hackney:finish_send_body(Ref) of
        ok ->
            Resp =  hackney:start_response(Ref),
            reply_att(Resp);
        Error ->
            Error
    end;
send_attachment(Ref, Msg) ->
    Reply = hackney:send_body(Ref, Msg),
    reply_att(Reply).


%% @doc delete a document attachment
%% @equiv delete_attachment(Db, Doc, Name, [])
delete_attachment(Db, Doc, Name) ->
    delete_attachment(Db, Doc, Name, []).

%% @doc delete a document attachment
%% @spec(db(), string()|list(), string(), list() -> {ok, Result} | {error, Error}
delete_attachment(#db{server=Server, options=Opts}=Db, DocOrDocId, Name,
                  Options) ->
    Options1 = couchbeam_util:parse_options(Options),
    {Rev, DocId} = case DocOrDocId of
        {Props} ->
            Rev1 = couchbeam_util:get_value(<<"_rev">>, Props),
            DocId1 = couchbeam_util:get_value(<<"_id">>, Props),
            {Rev1, DocId1};
        DocId1 ->
            Rev1 = couchbeam_util:get_value("rev", Options1),
            {Rev1, DocId1}
    end,
    case Rev of
        undefined ->
           {error, rev_undefined};
        _ ->
            Options2 = case couchbeam_util:get_value("rev", Options1) of
                undefined ->
                    [{<<"rev">>, couchbeam_util:to_binary(Rev)}|Options1];
                _ ->
                    Options1
            end,
            Url = hackney_url:make_url(server_url(Server), [db_url(Db),
                                                            DocId,
                                                            Name],
                                       Options2),

            case couchbeam_httpc:db_request(delete, Url, [], <<>>, Opts,
                                            [200]) of
            {ok, _, _, Ref} ->
                {[{<<"ok">>,true}|R]} = couchbeam_httpc:json_body(Ref),
                {ok, {R}};
            Error ->
                Error
            end
    end.

%% @doc commit all docs in memory
%% @equiv ensure_full_commit(Db, [])
ensure_full_commit(Db) ->
    ensure_full_commit(Db, []).

%% @doc commit all docs in memory
%% @spec ensure_full_commit(Db::db(), Options::list())
%%                      -> {ok, term()}|{error, term()}
ensure_full_commit(#db{server=Server, options=Opts}=Db, Options) ->
    Url = hackney_url:make_url(server_url(Server), [db_url(Db),
                                                    <<"_ensure_full_commit">>],
                               Options),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case couchbeam_httpc:db_request(post, Url, Headers, <<>>, Opts, [201]) of
        {ok, _, _, Ref} ->
            {[{<<"ok">>, true}|R]} = couchbeam_httpc:json_body(Ref),
            {ok, R};
        Error ->
            Error
    end.

%% @doc Compaction compresses the database file by removing unused
%% sections created during updates.
%% See [http://wiki.apache.org/couchdb/Compaction] for more informations
%% @spec compact(Db::db()) -> ok|{error, term()}
compact(#db{server=Server, options=Opts}=Db) ->
    Url = hackney_url:make_url(server_url(Server), [db_url(Db),
                                                    <<"_compact">>],
                               []),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case couchbeam_httpc:db_request(post, Url, Headers, <<>>, Opts, [202]) of
        {ok, _, _, Ref} ->
            hackney:skip_body(Ref),
            ok;
        Error ->
            Error
    end.
%% @doc Like compact/1 but this compacts the view index from the
%% current version of the design document.
%% See [http://wiki.apache.org/couchdb/Compaction#View_compaction] for more informations
%% @spec compact(Db::db(), ViewName::string()) -> ok|{error, term()}
compact(#db{server=Server, options=Opts}=Db, DesignName) ->
    Url = hacney_url:make_url(server_url(Server), [db_url(Db),
                                                   <<"_compact">>,
                                                   DesignName], []),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case couchbeam_httpc:db_request(post, Url, Headers, <<>>, Opts, [202]) of
        {ok, _, _, Ref} ->
            hackney:skip_body(Ref),
            ok;
        Error ->
            Error
    end.


%% --------------------------------------------------------------------
%% Utilities functions.
%% --------------------------------------------------------------------

%% add missing docid to a list of documents if needed
maybe_docid(Server, {DocProps}) ->
    case couchbeam_util:get_value(<<"_id">>, DocProps) of
        undefined ->
            [DocId] = get_uuid(Server),
            {[{<<"_id">>, DocId}|DocProps]};
        _DocId ->
            {DocProps}
    end.

%% @doc Asemble the server URL for the given client
%% @spec server_url({Host, Port}) -> iolist()
server_url(#server{url=Url}) ->
    Url.

dbname(DbName) when is_list(DbName) ->
    list_to_binary(DbName);
dbname(DbName) when is_binary(DbName) ->
    DbName;
dbname(DbName) ->
    erlang:error({illegal_database_name, DbName}).

db_url(#db{name=DbName}) ->
    DbName.

doc_url(Db, DocId) ->
    iolist_to_binary([db_url(Db), <<"/">>, DocId]).

reply_att(ok) ->
    ok;
reply_att(done) ->
    done;
reply_att({ok, 200, _, Ref}) ->
    {[{<<"ok">>, true}|R]} = couchbeam_httpc:json_body(Ref),
            {ok, {R}};
reply_att({ok, 404, _, Ref}) ->
    hackney:skip_body(Ref),
    {error, not_found};
reply_att({ok, 409, _, Ref}) ->
    hackney:skip_body(Ref),
    {error, conflict};
reply_att({ok, Status, Headers, Ref}) ->
    {ok, Body} = hackney:body(Ref),
    {error, {bad_response, {Status, Headers, Body}}};
reply_att(Error) ->
    Error.
