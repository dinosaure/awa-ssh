(*
 * Copyright (c) 2017 Christiano F. Haesbaert <haesbaert@haesbaert.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Sexplib.Conv
open Rresult.R
open Util

[%%cstruct
type pkt_hdr = {
  pkt_len: uint32_t;
  pad_len: uint8_t;
} [@@big_endian]]

(** {2 Version exchange parser.} *)

let scan_version buf =
  let s = Cstruct.to_string buf in
  let len = String.length s in
  let not_found =
    if len < (1024 * 64) then
      ok None
    else
      error "Buffer is too big"
  in
  let rec scan start off =
    if off = len then
      not_found
    else
      match (String.get s (pred off), String.get s off) with
      | ('\r', '\n') ->
        let line = String.sub s start (off - start - 1) in
        let line_len = String.length line in
        if line_len < 4 ||
           String.sub line 0 4 <> "SSH-" then
          scan (succ off) (succ off)
        else if (line_len < 9) then
          error "Version line is too short"
        else
          let tokens = Str.split_delim (Str.regexp "-") line in
          if List.length tokens <> 3 then
            error "Can't parse version line"
          else
            let version = List.nth tokens 1 in
            let peer_version = List.nth tokens 2 in
            if version <> "2.0" then
              error ("Bad version " ^ version)
            else
              safe_shift buf (succ off) >>= fun buf ->
              ok (Some (buf, peer_version))
      | _ -> scan start (succ off)
  in
  if len < 2 then
    not_found
  else
    scan 0 1

(** {2 Fetch the first packet and walk the buffer .} *)
let max_pkt_len = Int32.of_int 64000    (* 64KB should be enough *)

let scan_pkt buf =
  let len = Cstruct.len buf in
  let partial () =
    if len < (1024 * 64) then
      ok None
    else
      error "Buffer is too big"
  in
  if len < 4 then
    partial ()
  else
    let pkt_len32 = get_pkt_hdr_pkt_len buf in
    let pkt_len = Int32.to_int pkt_len32 in
    let pad_len = get_pkt_hdr_pad_len buf in
    (* XXX remember mac_len *)
    guard
      (pkt_len <> 0 &&
       ((u32_compare pkt_len32 max_pkt_len) < 0) &&
       (pkt_len > pad_len + 1))
      "Malformed packet"
    >>= fun () ->
    assert (len > 4);
    if pkt_len > (len - 4) then
      partial ()
    else
      let payload_len = pkt_len - pad_len - 1 in
      let clen =
        4 +                (* pkt_len field itself *)
        pkt_len +          (* size of this packet  *)
        pad_len            (* padding after packet *)
                           (* XXX mac_len missing !*)
      in
      safe_sub buf sizeof_pkt_hdr payload_len >>= fun pkt ->
      ok (Some (pkt, clen))

(** {2 Message ID.} *)

[%%cenum
type message_id =
  | SSH_MSG_DISCONNECT                [@id 1]
  | SSH_MSG_IGNORE                    [@id 2]
  | SSH_MSG_UNIMPLEMENTED             [@id 3]
  | SSH_MSG_DEBUG                     [@id 4]
  | SSH_MSG_SERVICE_REQUEST           [@id 5]
  | SSH_MSG_SERVICE_ACCEPT            [@id 6]
  | SSH_MSG_KEXINIT                   [@id 20]
  | SSH_MSG_NEWKEYS                   [@id 21]
  | SSH_MSG_USERAUTH_REQUEST          [@id 50]
  | SSH_MSG_USERAUTH_FAILURE          [@id 51]
  | SSH_MSG_USERAUTH_SUCCESS          [@id 52]
  | SSH_MSG_USERAUTH_BANNER           [@id 53]
  | SSH_MSG_GLOBAL_REQUEST            [@id 80]
  | SSH_MSG_REQUEST_SUCCESS           [@id 81]
  | SSH_MSG_REQUEST_FAILURE           [@id 82]
  | SSH_MSG_CHANNEL_OPEN              [@id 90]
  | SSH_MSG_CHANNEL_OPEN_CONFIRMATION [@id 91]
  | SSH_MSG_CHANNEL_OPEN_FAILURE      [@id 92]
  | SSH_MSG_CHANNEL_WINDOW_ADJUST     [@id 93]
  | SSH_MSG_CHANNEL_DATA              [@id 94]
  | SSH_MSG_CHANNEL_EXTENDED_DATA     [@id 95]
  | SSH_MSG_CHANNEL_EOF               [@id 96]
  | SSH_MSG_CHANNEL_CLOSE             [@id 97]
  | SSH_MSG_CHANNEL_REQUEST           [@id 98]
  | SSH_MSG_CHANNEL_SUCCESS           [@id 99]
  | SSH_MSG_CHANNEL_FAILURE           [@id 100]
[@@uint8_t][@@sexp]]

let decode_message_id buf =
  int_to_message_id (Cstruct.get_uint8 buf 0)

let encode_message_id m =
  let buf = Cstruct.create 1 in
  Cstruct.set_uint8 buf 0 (message_id_to_int m);
  buf

let assert_message_id buf msgid =
  assert ((decode_message_id buf) = Some msgid)

(** {2 Conversions on primitives from RFC4251 5.} *)

let decode_string buf off =
  (* XXX bad to_int conversion *)
  trap_error (fun () ->
      let len = Cstruct.BE.get_uint32 buf off |> Int32.to_int in
      (Cstruct.copy buf (off + 4) len), len) ()

let encode_string s =
  let len = String.length s in
  if len > 255 then
      invalid_arg "String is too long";
  let buf = Cstruct.create (len + 4) in
  Cstruct.BE.set_uint32 buf 0 (Int32.of_int len);
  Cstruct.blit_from_string s 0 buf 4 len;
  buf

let encode_cstring c =
  trap_error (fun () ->
      let len = Cstruct.len c in
      if len > 255 then
        invalid_arg "Cstruct string is too long";
      let buf = Cstruct.create (len + 4) in
      Cstruct.BE.set_uint32 buf 0 (Int32.of_int len);
      Cstruct.blit c 0 buf 4 len;
      buf) ()

let decode_mpint buf off =
  trap_error (fun () ->
      (Cstruct.BE.get_uint32 buf off) |> Int32.to_int) ()
  >>= function
  | 0 -> ok (Cstruct.create 0)
  | len ->
    safe_sub buf (off + 4) len >>= fun buf ->
    let msb = Cstruct.get_uint8 buf 0 in
    if (msb land 0x80) <> 0 then
      error "Negative mpint"
    else
      let rec leading_zeros off sum =
        if off = len then
          sum
        else if (Cstruct.get_uint8 buf off) = 0 then
          leading_zeros (succ off) (succ sum)
        else
          leading_zeros (succ off) sum
      in
      safe_shift buf (leading_zeros 0 0)

let encode_mpint mpint =
  let len = Cstruct.len mpint in
  if len > 0 &&
     ((Cstruct.get_uint8 mpint 0) land 0x80) <> 0 then
    let head = Cstruct.create 5 in
    Cstruct.set_uint8 head 4 0;
    Cstruct.BE.set_uint32 head 0 (Int32.of_int (succ len));
    Cstruct.append head mpint
  else
    let head = Cstruct.create 4 in
    Cstruct.BE.set_uint32 head 0 (Int32.of_int len);
    Cstruct.append head mpint

let encode_rsa (rsa : Nocrypto.Rsa.pub) =
  let open Nocrypto in
  let s = encode_string "ssh-rsa" in
  let e = encode_mpint (Numeric.Z.to_cstruct_be rsa.Rsa.e) in
  let n = encode_mpint (Numeric.Z.to_cstruct_be rsa.Rsa.n) in
  Cstruct.concat [s; e; n]

let decode_uint32 buf off =
  trap_error (fun () -> Cstruct.BE.get_uint32 buf off) ()

let encode_uint32 v =
  let buf = Cstruct.create 4 in
  Cstruct.BE.set_uint32 buf 0 v;
  buf

let decode_bool buf off =
  trap_error (fun () -> (Cstruct.get_uint8 buf 0) <> 0) ()

let encode_bool b =
  let buf = Cstruct.create 1 in
  Cstruct.set_uint8 buf 0 (if b then 1 else 0);
  buf

let encode_nl nl =
  encode_string (String.concat "," nl)

let decode_nl buf off =
  decode_string buf off >>= fun (s, len) ->
  ok ((Str.split (Str.regexp ",") s), len)

let decode_nll buf n =
  let rec loop buf l tlen =
    if (List.length l) = n then
      ok (List.rev l, tlen)
    else
      decode_nl buf 0 >>= fun (nl, len) ->
      safe_shift buf (len + 4) >>= fun buf ->
      loop buf (nl :: l) (len + tlen + 4)
  in
  loop buf [] 0

(** {2 SSH_MSG_DISCONNECT RFC4253 11.1.} *)

let encode_disconnect code desc lang =
  let code = encode_uint32 code in
  let desc = encode_string desc in
  let lang = encode_string lang in
  Cstruct.concat [encode_message_id SSH_MSG_KEXINIT; code; desc; lang]

(** {2 SSH_MSG_KEXINIT RFC4253 7.1.} *)

type kex_pkt = {
  cookie : string;
  kex_algorithms : string list;
  server_host_key_algorithms : string list;
  encryption_algorithms_ctos : string list;
  encryption_algorithms_stoc : string list;
  mac_algorithms_ctos : string list;
  mac_algorithms_stoc : string list;
  compression_algorithms_ctos : string list;
  compression_algorithms_stoc : string list;
  languages_ctos : string list;
  languages_stoc : string list;
  first_kex_packet_follows : bool
} [@@deriving sexp]

let encode_kex kex =
  let f = encode_nl in
  let nll = Cstruct.concat
      [ f kex.kex_algorithms;
        f kex.server_host_key_algorithms;
        f kex.encryption_algorithms_ctos;
        f kex.encryption_algorithms_stoc;
        f kex.mac_algorithms_ctos;
        f kex.mac_algorithms_stoc;
        f kex.compression_algorithms_ctos;
        f kex.compression_algorithms_stoc;
        f kex.languages_ctos;
        f kex.languages_stoc; ]
  in
  let head = encode_message_id SSH_MSG_KEXINIT in
  let cookie = Cstruct.create 16 in
  assert ((String.length kex.cookie) = 16);
  Cstruct.blit_from_string kex.cookie 0 cookie 0 16;
  let tail = Cstruct.create 5 in  (* first_kex_packet_follows + reserved *)
  Cstruct.set_uint8 tail 0 (if kex.first_kex_packet_follows then 1 else 0);
  Cstruct.concat [head; cookie; nll; tail]

(** {2 SSH_MSG_USERAUTH_REQUEST RFC4252 5.} *)

(* TODO, variable len *)

(** {2 SSH_MSG_USERAUTH_FAILURE RFC4252 5.1} *)

let encode_userauth_failure nl psucc =
  let head = encode_message_id SSH_MSG_USERAUTH_FAILURE in
  Cstruct.concat [head; encode_nl nl; encode_bool psucc]

(** {2 SSH_MSG_GLOBAL_REQUEST RFC4254 4.} *)

(* TODO, variable len *)

(** {2 High level representation of messages, one for each message_id. } *)

type message =
  | Ssh_msg_disconnect of (int32 * string * string)
  | Ssh_msg_ignore of (string * int)
  | Ssh_msg_unimplemented of int32
  | Ssh_msg_debug of (bool * string * string)
  | Ssh_msg_service_request of (string * int)
  | Ssh_msg_service_accept of (string * int)
  | Ssh_msg_kexinit of kex_pkt
  | Ssh_msg_newkeys
  | Ssh_msg_userauth_request
  | Ssh_msg_userauth_failure of (string list * bool)
  | Ssh_msg_userauth_success
  | Ssh_msg_userauth_banner of (string * string)
  | Ssh_msg_global_request
  | Ssh_msg_request_success
  | Ssh_msg_request_failure
  | Ssh_msg_channel_open
  | Ssh_msg_channel_open_confirmation
  | Ssh_msg_channel_open_failure
  | Ssh_msg_channel_window_adjust
  | Ssh_msg_channel_data
  | Ssh_msg_channel_extended_data
  | Ssh_msg_channel_eof
  | Ssh_msg_channel_close
  | Ssh_msg_channel_request
  | Ssh_msg_channel_success
  | Ssh_msg_channel_failure

let message_of_buf buf =
  match decode_message_id buf with
  | None -> error "Unknown message id"
  | Some msgid ->
    let unimplemented () =
      error (Printf.sprintf "Message %d unimplemented" (message_id_to_int msgid))
    in
    match msgid with
    | SSH_MSG_DISCONNECT ->
      decode_uint32 buf 1 >>= fun code ->
      decode_string buf 5 >>= fun (desc, len) ->
      decode_string buf (len + 9) >>= fun (lang, _) ->
      ok (Ssh_msg_disconnect (code, desc, lang))
    | SSH_MSG_IGNORE ->
      decode_string buf 1 >>= fun x ->
      ok (Ssh_msg_ignore x)
    | SSH_MSG_UNIMPLEMENTED ->
      decode_uint32 buf 1 >>= fun x ->
      ok (Ssh_msg_unimplemented x)
    | SSH_MSG_DEBUG ->
      decode_bool buf 1 >>= fun always_display ->
      decode_string buf 2 >>= fun (message, len) ->
      decode_string buf (len + 6) >>= fun (lang, _) ->
      ok (Ssh_msg_debug (always_display, message, lang))
    | SSH_MSG_SERVICE_REQUEST ->
      decode_string buf 1 >>= fun x -> ok (Ssh_msg_service_request x)
    | SSH_MSG_SERVICE_ACCEPT ->
      decode_string buf 1 >>= fun x -> ok (Ssh_msg_service_accept x)
    | SSH_MSG_KEXINIT ->
        safe_shift buf 17 >>= fun nllbuf ->
        decode_nll nllbuf 10 >>= fun (nll, nll_len) ->
        decode_bool buf nll_len >>= fun first_kex_packet_follows ->
        ok (Ssh_msg_kexinit
              { cookie = Cstruct.copy buf 1 16;
                kex_algorithms = List.nth nll 0;
                server_host_key_algorithms = List.nth nll 1;
                encryption_algorithms_ctos = List.nth nll 2;
                encryption_algorithms_stoc = List.nth nll 3;
                mac_algorithms_ctos = List.nth nll 4;
                mac_algorithms_stoc = List.nth nll 5;
                compression_algorithms_ctos = List.nth nll 6;
                compression_algorithms_stoc = List.nth nll 7;
                languages_ctos = List.nth nll 8;
                languages_stoc = List.nth nll 9;
                first_kex_packet_follows; })
    | SSH_MSG_NEWKEYS -> ok Ssh_msg_newkeys
    | SSH_MSG_USERAUTH_REQUEST -> unimplemented ()
    | SSH_MSG_USERAUTH_FAILURE ->
      decode_nl buf 1 >>= fun (nl, len) ->
      decode_bool buf len >>= fun psucc ->
      ok (Ssh_msg_userauth_failure (nl, psucc))
    | SSH_MSG_USERAUTH_SUCCESS -> unimplemented ()
    | SSH_MSG_USERAUTH_BANNER ->
      decode_string buf 1 >>= fun (s1, len1) ->
      decode_string buf (len1 + 5) >>= fun (s2, _) ->
      ok (Ssh_msg_userauth_banner (s1, s2))
    | SSH_MSG_GLOBAL_REQUEST -> unimplemented ()
    | SSH_MSG_REQUEST_SUCCESS -> unimplemented ()
    | SSH_MSG_REQUEST_FAILURE -> unimplemented ()
    | SSH_MSG_CHANNEL_OPEN -> unimplemented ()
    | SSH_MSG_CHANNEL_OPEN_CONFIRMATION -> unimplemented ()
    | SSH_MSG_CHANNEL_OPEN_FAILURE -> unimplemented ()
    | SSH_MSG_CHANNEL_WINDOW_ADJUST -> unimplemented ()
    | SSH_MSG_CHANNEL_DATA -> unimplemented ()
    | SSH_MSG_CHANNEL_EXTENDED_DATA -> unimplemented ()
    | SSH_MSG_CHANNEL_EOF -> unimplemented ()
    | SSH_MSG_CHANNEL_CLOSE -> unimplemented ()
    | SSH_MSG_CHANNEL_REQUEST -> unimplemented ()
    | SSH_MSG_CHANNEL_SUCCESS -> unimplemented ()
    | SSH_MSG_CHANNEL_FAILURE -> unimplemented ()

let scan_message buf =
  scan_pkt buf >>= function
  | None -> ok None
  | Some (pkt, clen) -> message_of_buf pkt >>= fun msg -> ok (Some msg)

(*
 * All below should be moved somewhere
 *)

(* e = client public *)
(* f = server public *)
(* y = server secret *)

   (* The following steps are used to exchange a key.  In this, C is the *)
   (* client; S is the server; p is a large safe prime; g is a generator *)
   (* for a subgroup of GF(p); q is the order of the subgroup; V_S is S's *)
   (* identification string; V_C is C's identification string; K_S is S's *)
   (* public host key; I_C is C's SSH_MSG_KEXINIT message and I_S is S's *)
   (* SSH_MSG_KEXINIT message that have been exchanged before this part *)
(* begins. *)

   (* The hash H is computed as the HASH hash of the concatenation of the *)
   (* following: *)

   (*    string    V_C, the client's identification string (CR and LF *)
   (*              excluded) *)
   (*    string    V_S, the server's identification string (CR and LF *)
   (*              excluded) *)
   (*    string    I_C, the payload of the client's SSH_MSG_KEXINIT *)
   (*    string    I_S, the payload of the server's SSH_MSG_KEXINIT *)
   (*    string    K_S, the host key *)
   (*    mpint     e, exchange value sent by the client *)
   (*    mpint     f, exchange value sent by the server *)
   (*    mpint     K, the shared secret *)

(* let dh_server_compute_hash ~rsa_secret ~v_c ~v_s ~i_c ~i_s ~e = *)
(*   let open Nocrypto in *)
(*   let rsa_pub = Rsa.pub_of_priv rsa_secret in *)
(*   let g = Dh.Group.oakley_14 in *)
(*   let y, f = Dh.gen_key g in *)
(*   guard_some (Dh.shared g y e) "Can't compute shared secret" *)
(*   >>= fun k -> *)
(*   encode_cstring v_c >>= fun v_c -> *)
(*   encode_cstring v_s >>= fun v_s -> *)
(*   encode_cstring i_c >>= fun i_c -> *)
(*   encode_cstring i_s >>= fun i_s -> *)
(*   let k_s = encode_rsa rsa_pub in *)
(*   let e = encode_mpint e in *)
(*   (\* f computed in Dh.gen_key *\) *)
(*   let h = Hash.SHA1.digestv [ v_c; v_s; i_c; i_s; k_s; e; f; k ] in *)
(*   let sig = Rsa.PKCS1.sig_encode rsa_secret h in *)

let dh_gen_keys g peer_pub =
  let secret, my_pub = Nocrypto.Dh.gen_key g in
  guard_some
    (Nocrypto.Dh.shared g secret peer_pub)
    "Can't compute shared secret"
  >>= fun shared ->
  (* secret is y, my_pub is f or e, shared is k *)
  ok (secret, my_pub, shared)

let dh_server_compute_hash ~v_c ~v_s ~i_c ~i_s ~k_s ~e ~f ~k =
  encode_cstring v_c >>= fun v_c ->
  encode_cstring v_s >>= fun v_s ->
  encode_cstring i_c >>= fun i_c ->
  encode_cstring i_s >>= fun i_s ->
  let e = encode_mpint e in
  let f = encode_mpint f in
  ok (Nocrypto.Hash.SHA1.digestv [ v_c; v_s; i_c; i_s; k_s; e; f; k ])

(* Only server obviously *)
let handle_kexdh_init e g rsa_secret =
  let v_c = Cstruct.create 0 in (* XXX *)
  let v_s = v_c in              (* XXX *)
  let i_c = v_c in              (* XXX *)
  let i_s = v_c in              (* XXX *)
  let rsa_pub = Nocrypto.Rsa.pub_of_priv rsa_secret in
  dh_gen_keys g e
  >>= fun (y, f, k) ->
  let k_s = encode_rsa rsa_pub in
  dh_server_compute_hash ~v_c ~v_s ~i_c ~i_s ~k_s ~e ~f ~k
  >>= fun h ->
  let signature = Nocrypto.Rsa.PKCS1.sig_encode rsa_secret h in
  ok ()
  (* ok (Ssh_msg_kexdh_reply k_s f signature) *)

type mode = Server | Client

let make_kex cookie =
  if (String.length cookie) <> 16 then
    invalid_arg "Bad cookie len";
  { cookie;
    kex_algorithms = [ "diffie-hellman-group14-sha1";
                       "diffie-hellman-group1-sha1" ];
    server_host_key_algorithms = [ "ssh-rsa" ];
    encryption_algorithms_ctos = [ "aes128-ctr" ];
    encryption_algorithms_stoc = [ "aes128-ctr" ];
    mac_algorithms_ctos = [ "hmac-sha1" ];
    mac_algorithms_stoc = [ "hmac-sha1" ];
    compression_algorithms_ctos = [ "none" ];
    compression_algorithms_stoc = [ "none" ];
    languages_ctos = [];
    languages_stoc = [];
    first_kex_packet_follows = false }

let handle_kex mode kex =
  let us = make_kex (Bytes.create 16) in
  let s = if mode = Server then us else kex in
  let c = if mode = Server then kex else us in
  let pick_common ~s ~c e =
    try
      Ok (List.find (fun x -> List.mem x s) c)
    with
      Not_found -> Error e
  in
  pick_common
    ~s:s.kex_algorithms
    ~c:c.kex_algorithms
    "Can't agree on kex algorithm"
  >>= fun kex_algorithms ->
  pick_common
    ~s:s.encryption_algorithms_ctos
    ~c:c.encryption_algorithms_ctos
    "Can't agree on encryption algorithm client to server"
  >>= fun encryption_algorithms_ctos ->
  pick_common
    ~s:s.encryption_algorithms_stoc
    ~c:c.encryption_algorithms_stoc
    "Can't agree on encryption algorithm server to client"
  >>= fun encryption_algorithms_stoc ->
  pick_common
    ~s:s.mac_algorithms_ctos
    ~c:c.mac_algorithms_ctos
    "Can't agree on mac algorithm client to server"
  >>= fun mac_algorithms_ctos ->
  pick_common
    ~s:s.mac_algorithms_stoc
    ~c:c.mac_algorithms_stoc
    "Can't agree on mac algorithm server to client"
  >>= fun mac_algorithms_stoc ->
  pick_common
    ~s:s.compression_algorithms_ctos
    ~c:c.compression_algorithms_ctos
    "Can't agree on compression algorithm client to server"
  >>= fun compression_algorithms_ctos ->
  pick_common
    ~s:s.compression_algorithms_stoc
    ~c:c.compression_algorithms_stoc
    "Can't agree on compression algorithm server to client"
  >>= fun compression_algorithms_stoc ->
  (* XXX ignore languages for now *)
  (* XXX this will be provided in the future, obviously *)
  let rsa_priv = Nocrypto.Rsa.generate 4096 in
  let rsa_pub = Nocrypto.Rsa.pub_of_priv rsa_priv in
    (*
     * secret is x
     * public is g^x
     * shared is shared g14 secret public
     *)
  let secret, public = Nocrypto.Dh.(gen_key Group.oakley_14) in
  Ok (secret, public)