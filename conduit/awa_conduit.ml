type endpoint =
  { authenticator : Awa.Keys.authenticator option
  ; user : string
  ; key : Awa.Hostkey.priv
  ; req : Awa.Ssh.channel_request }

module Make
    (IO : Conduit.IO)
    (Conduit : Conduit.S
                 with type input = Cstruct.t
                  and type output = Cstruct.t
                  and type +'a io = 'a IO.t)
    (M : Mirage_clock.MCLOCK)
= struct
  let return x = IO.return x
  let ( >>= ) x f = IO.bind x f
  let ( >>| ) x f = x >>= fun x -> return (f x)
  let ( >>? ) x f = x >>= function
    | Ok x -> f x
    | Error _ as err -> return err

  let reword_error f = function
    | Ok _ as v -> v
    | Error err -> Error (f err)

  type 'flow protocol_with_ssh = {
    mutable ssh : Awa.Client.t ;
    mutable uid : int32 option ;
    mutable closed : closed ;
    raw : Cstruct.t ;
    flow : 'flow ;
    queue : (char, Bigarray.int8_unsigned_elt) Ke.Rke.t ;
  } and closed =
      | Exited of int32
      | Eof
      | None

  let is_close : closed -> bool = function
    | None -> false | _ -> true

  let src = Logs.Src.create "conduit-ssh"

  module Log = (val Logs.src_log src : Logs.LOG)

  module Make_protocol
      (Flow : Conduit.PROTOCOL
                with type input = Conduit.input
                 and type output = Conduit.output
                 and type +'a io = 'a IO.t) =
    struct
      type input = Conduit.input
      type output = Conduit.output
      type +'a io = 'a Conduit.io

      type nonrec endpoint = Flow.endpoint * endpoint

      type flow = Flow.flow protocol_with_ssh

      type error =
        [ `Flow of Flow.error
        | `SSH of string
        | `Closed_by_peer
        | `Handshake_aborted ]

      let pp_error : error Fmt.t = fun ppf -> function
        | `Flow err -> Flow.pp_error ppf err
        | `SSH err -> Fmt.string ppf err
        | `Closed_by_peer -> Fmt.string ppf "Closed by peer"
        | `Handshake_aborted -> Fmt.string ppf "Handshake aborted"

      let flow_error err = `Flow err

      let writev flow cs =
        let rec one v =
          if Cstruct.len v = 0 then return (Ok ())
          else Flow.send flow v >>? fun len ->
            one (Cstruct.shift v len)
        and go = function
          | [] -> return (Ok ())
          | x :: r -> one x >>? fun () -> go r in
        go cs

      let blit src src_off dst dst_off len =
        let src = Cstruct.to_bigarray src in
        Bigstringaf.blit src ~src_off dst ~dst_off ~len

      let write queue v =
        Log.debug (fun m -> m "Got %S." (Cstruct.to_string v)) ;
        Ke.Rke.N.push queue ~blit ~length:Cstruct.len ~off:0 v

      let handle_event t = function
        | `Established uid -> t.uid <- Some uid
        | `Channel_data (uid, data) ->
          if Option.(fold ~none:false ~some:(Int32.equal uid) t.uid)
          then write t.queue data else ()
        | `Channel_eof uid ->
          if Option.(fold ~none:false ~some:(Int32.equal uid) t.uid)
          then t.closed <- Eof else ()
        | `Channel_exit_status (uid, n) ->
          if Option.(fold ~none:false ~some:(Int32.equal uid) t.uid)
          then t.closed <- Exited n else ()
        | `Disconnected -> t.uid <- None

      let rec handle t =
        Flow.recv t.flow t.raw >>| reword_error flow_error >>? function
        | `End_of_flow ->
          t.uid <- None ;
          t.closed <- Eof ;
          return (Ok ())
        | `Input len ->
          let raw = Cstruct.sub t.raw 0 len in
          match t.uid, Awa.Client.incoming t.ssh (Mtime.of_uint64_ns (M.elapsed_ns ())) raw with
          | _, Error err -> return (Error (`SSH err))
          | None, Ok (ssh, out, events) ->
            List.iter (handle_event t) events ; t.ssh <- ssh ;
            writev t.flow out >>| reword_error flow_error >>? fun () ->
            if Option.is_none t.uid && not (is_close t.closed)
            then handle t else return (Ok ())
          | Some _, Ok (ssh, out, events) ->
            List.iter (handle_event t) events ; t.ssh <- ssh ;
            writev t.flow out >>| reword_error flow_error >>? fun () ->
            return (Ok ())

      let connect (edn, { authenticator; user; key; req; }) =
        Log.debug (fun m -> m "Start a SSH connection with a peer.") ;
        Flow.connect edn >>| reword_error flow_error >>? fun flow ->
        Log.debug (fun m -> m "Connected to our peer.") ;
        let ssh, bufs = Awa.Client.make ?authenticator ~user key in
        Log.debug (fun m -> m "SSH State initialized.") ;
        let raw = Cstruct.create 0x1000 in
        let queue = Ke.Rke.create ~capacity:0x1000 Bigarray.Char in
        Log.debug (fun m -> m "Start a handshake SSH.") ;
        writev flow bufs >>| reword_error flow_error >>? fun () ->
        let t = { ssh; uid= None; closed= None; flow; raw; queue; } in
        handle t >>? fun () ->
        match t.uid with
        | None -> t.closed <- Eof ; return (Error `Handshake_aborted)
        | Some uid ->
          Log.debug (fun m -> m "Handshake is done.") ;
          match Awa.Client.outgoing_request t.ssh ~id:uid req with
          | Error err -> return (Error (`SSH err))
          | Ok (ssh, out) ->
            t.ssh <- ssh ; writev flow [ out ] >>| reword_error flow_error >>? fun () ->
            return (Ok t)

      let blit src src_off dst dst_off len =
        let dst = Cstruct.to_bigarray dst in
        Bigstringaf.blit src ~src_off dst ~dst_off ~len

      let rec recv t raw =
        Log.debug (fun m -> m "Start to read incoming data.") ;
        match Ke.Rke.N.peek t.queue with
        | [] ->
          if not (is_close t.closed)
          then handle t >>? fun () -> recv t raw
          else return (Ok `End_of_flow)
        | _ ->
          let max = Cstruct.len raw in
          let len = min (Ke.Rke.length t.queue) max in
          Ke.Rke.N.keep_exn t.queue ~blit ~length:Cstruct.len ~off:0 ~len raw ;
          Ke.Rke.N.shift_exn t.queue len ;
          return (Ok (`Input len))

      let send t raw =
        if is_close t.closed
        then return (Error `Closed_by_peer)
        else
          ( Log.debug (fun m -> m "Start encrypt outgoing data.\n%!" )
          ; match Awa.Client.outgoing_data t.ssh raw with
          | Ok (ssh, out) ->
            writev t.flow out >>| reword_error flow_error >>? fun () ->
            t.ssh <- ssh ; return (Ok (Cstruct.len raw))
          | Error err ->
            return (Error (`SSH err)) )

      let close t =
        t.closed <- Eof ; Flow.close t.flow >>| reword_error flow_error
    end

  let protocol_with_ssh :
    type edn flow.
    (edn, flow) Conduit.protocol ->
    (edn * endpoint, flow protocol_with_ssh) Conduit.protocol =
    fun protocol ->
    let module Flow = (val (Conduit.impl protocol)) in
    let module M = Make_protocol (Flow) in
    Conduit.register ~protocol:(module M)
end
