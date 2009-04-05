-module(realm_crypto).
-compile(export_all).

-include("realm_records.hrl").

-define(I, /unsigned-integer).
-define(IB, /unsigned-integer-big).
-define(IL, /unsigned-integer-little).
-define(K, 20).

%% @spec encrypt(binary(), binary()) -> binary().
encrypt(Header, Key) ->
    encrypt(Header, Key, <<>>).

%% @spec encrypt(binary(), binary(), binary()) -> binary().
encrypt(<<>>, Key, Result) -> {Result, Key};
encrypt(<<OldByte:8?I, Header/binary>>, #crypt_state{i = SI, j = SJ, key = K} = C, Result) ->
    NewByte = ((lists:nth(SI+1, K) bxor OldByte) + SJ) band 255,
    NewSI   = (SI+1) rem ?K,
    encrypt(Header, C#crypt_state{i  = NewSI, j  = NewByte}, <<Result/binary, NewByte:8>>).

%% @spec decrypt(binary(), binary()) -> binary().
decrypt(Header, Key) ->
    decrypt(Header, Key, <<>>).

%% @spec decrypt(binary(), binary(), binary()) -> binary().
decrypt(<<>>, Key, Result) -> {Result, Key};
decrypt(<<OldByte:8?I, Header/binary>>, #crypt_state{i = RI, j = RJ, key = K} = C, Result) ->
    NewByte = (lists:nth(RI+1, K) bxor (OldByte - RJ)) band 255,
    NewRI   = (RI + 1) rem ?K,
    decrypt(Header, C#crypt_state{i = NewRI, j = OldByte}, <<Result/binary, NewByte:8>>).

%% @spec encrypt(string()) -> list().
encryption_key(A) ->
    [{_, K}] = ets:lookup(connected_clients, A),
    Seed = 16#38A78315F8922530719867B18C04E2AA,
    binary_to_list(crypto:sha_mac(<<Seed:128?IB>>, K)).
