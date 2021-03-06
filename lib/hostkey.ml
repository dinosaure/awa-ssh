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

open Mirage_crypto_pk

type priv =
  | Rsa_priv of Rsa.priv

type pub =
  | Rsa_pub of Rsa.pub
  | Unknown

let pub_of_priv = function
  | Rsa_priv priv -> Rsa_pub (Rsa.pub_of_priv priv)

let sexp_of_pub _ = Sexplib.Sexp.Atom "Hostkey.sexp_of_pub: TODO"
let pub_of_sexp _ = failwith "Hostkey.pub_of_sexp: TODO"

let sshname = function
  | Rsa_pub _ -> "ssh-rsa"
  | Unknown -> "unknown"

let signature_equal = Cstruct.equal

let sign priv blob =
  match priv with
  | Rsa_priv priv ->
    Rsa.PKCS1.sign ~hash:`SHA1 ~key:priv (`Message blob)

let verify pub ~unsigned ~signed =
  match pub with
  | Unknown -> false
  | Rsa_pub pub ->
    let hashp = function `SHA1 -> true | _ -> false in
    Rsa.PKCS1.verify ~hashp ~key:pub ~signature:signed (`Message unsigned)
