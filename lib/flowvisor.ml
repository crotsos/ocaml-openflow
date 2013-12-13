(*
 * Copyright (c) 2011 Charalampos Rotsos <cr409@cl.cam.ac.uk> 
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

open Lwt
open Net

module OP = Openflow.Ofpacket
module OC = Openflow.Ofcontroller 
module OE = Openflow.Ofcontroller.Event 
module OSK = Openflow.Ofsocket
open OP
open OP.Flow 
open OP.Flow_mod 
open OP.Match 
 
let sp = Printf.sprintf
let cp = OS.Console.log
let to_port = OP.Port.port_of_int
let of_port = OP.Port.int_of_port

exception Ofcontroller_error of int32 * OP.error_code * OP.t 
exception Ofswitch_error of int64 * int32 * OP.error_code * OP.t

(* fake switch state to be exposed to controllers *)
type port = {
  port_id: int;
  port_name: string;
  phy: OP.Port.phy;
  origin_dpid: int64;
  origin_port_id: int;
}

type cached_reply = 
  | Flows of OP.Flow.stats list
  | Aggr of OP.Stats.aggregate
  | Table of OP.Stats.table 
  | Port of OP.Port.stats list
  | No_reply 

type xid_state = {
  xid : int32;
  src : int64;
  mutable dst : int64 list;
  ts : float;
  mutable cache : cached_reply;
}

type t = {
  verbose : bool;
  (* counters *)
  mutable errornum : int32; 
  mutable portnum : int;
  mutable xid_count : int32;
  mutable buffer_id_count: int32;
  
  (* controller and switch storage *)
  mutable controllers : (int64 * OP.Match.t *Openflow.Ofsocket.conn_state ) list;
  switches : (int64, OC.t) Hashtbl.t;
   
  (* Mapping transients id values *)
  xid_map : (int32, xid_state) Hashtbl.t;
  port_map : (int, (int64 * int * OP.Port.phy)) Hashtbl.t;
  buffer_id_map : (int32, (OP.Packet_in.t * int64)) Hashtbl.t;
 
  (* topology managment module *)
  flv_topo: Flowvisor_topology.t;
}

(* timeout pending queries after 3 minutes *)
let timeout = 180.

let supported_actions () = 
  OP.Switch.(
    {output=true;set_vlan_id=true;set_vlan_pcp=true;strip_vlan=true;
    set_dl_src=true; set_dl_dst=true; set_nw_src=true; set_nw_dst=true;
    set_nw_tos=true; set_tp_src=true; set_tp_dst=true; enqueue=false;
    vendor=false; })

let supported_capabilities () = 
  OP.Switch.({flow_stats=true;table_stats=true;port_stats=true;stp=false;
              ip_reasm=false;queue_stats=false;arp_match_ip=true;})

let switch_features datapath_id ports = 
  OP.Switch.({datapath_id; n_buffers=0l; n_tables=(char_of_int 1); 
              capabilities=(supported_capabilities ()); 
              actions=(supported_actions ()); ports;})

let init_flowvisor verbose flv_topo =
  {verbose; errornum=0l; portnum=10; xid_count=0l;
   port_map=(Hashtbl.create 64);
   controllers=[]; buffer_id_map=(Hashtbl.create 64);
   buffer_id_count=0l; xid_map=(Hashtbl.create 64); 
   switches=(Hashtbl.create 64); flv_topo; }

(* xid buffer controller functions *)
let match_dpid_buffer_id st dpid buffer_id = 
  try
    let (_, dst_dpid) = Hashtbl.find st.buffer_id_map buffer_id in 
      (dpid = dst_dpid)
  with Not_found -> false
let get_new_xid old_xid st src dst cache = 
  let xid = st.xid_count in 
  let _ = st.xid_count <- Int32.add st.xid_count 1l in 
  let r = {xid; src; dst; ts=(OS.Clock.time ()); cache;} in 
  let _ = Hashtbl.replace st.xid_map xid r in
    xid

let handle_xid flv st xid_st = 
  match xid_st.cache with 
  | Flows flows -> 
    let stats = OP.Stats.({st_ty=FLOW; more=true;}) in
    let (_, _, t) = List.find (
      fun (dpid, _, _) -> dpid = xid_st.src )
      flv.controllers in 
    lwt (_, flows) = 
      Lwt_list. fold_right_s (
        fun fl (sz, flows) ->
          let fl_sz = OP.Flow.flow_stats_len fl in 
          if (sz + fl_sz > 0xffff) then 
            let r = OP.Stats.Flow_resp(stats, flows) in
            let h = OP.Header.create ~xid:(xid_st.xid) OP.Header.STATS_RESP 0 in 
            lwt _ = Openflow.Ofsocket.send_packet t (OP.Stats_resp (h, r)) in
            return ((OP.Header.get_len + OP.Stats.get_resp_hdr_size + fl_sz), [fl])
          else
            return ((sz + fl_sz), (fl::flows)) )
      flows ((OP.Header.get_len + OP.Stats.get_resp_hdr_size), []) in 
    let stats = OP.Stats.({st_ty=FLOW; more=false;}) in 
    let r = OP.Stats.Flow_resp(stats, flows) in
    let h = OP.Header.create ~xid:xid_st.xid OP.Header.STATS_RESP 0 in 
      Openflow.Ofsocket.send_packet t (OP.Stats_resp (h, r)) 
  | _ -> return ()

let timeout_xid flv st = 
  while_lwt true do
    let time = OS.Clock.time () in
    let xid = 
      Hashtbl.fold (
        fun xid r ret ->
          if (r.ts+.timeout>time) then 
            let _ = Hashtbl.remove st.xid_map xid in 
            r :: ret 
          else ret
      ) st.xid_map [] in 
    lwt _ = Lwt_list.iter_p (handle_xid flv st) xid in 
      OS.Time.sleep 600.  
  done

(* communication primitives *)
let switch_dpid flv = Hashtbl.fold (fun dpid _ r -> r@[dpid]) flv.switches []
let switch_chan_dpid flv = Hashtbl.fold (fun dpid ch r -> (dpid,ch)::r) flv.switches []
let dpid_of_port st inp =     
  try 
    let (in_dpid, _, _) = Hashtbl.find st.port_map (of_port inp)  in 
    in_dpid
  with Not_found -> 0L
let port_of_port st inp =     
  try 
    let (_, inp, _) = Hashtbl.find st.port_map (of_port inp)  in 
    OP.Port.Port(inp)
  with Not_found -> OP.Port.No_port
let dpid_port_of_port_exn st inp xid msg =     
  try 
    let (dpid, p, _) = Hashtbl.find st.port_map (of_port inp)  in
    (dpid, OP.Port.Port(p))
  with Not_found -> 
    raise (Ofcontroller_error (xid, OP.ACTION_BAD_OUT_PORT, msg) )



let send_all_switches st msg =
  Lwt_list.iter_p (
    fun (dpid, ch) -> OC.send_data ch dpid msg) 
  (Hashtbl.fold (fun dpid ch c -> c @[(dpid, ch)]) st.switches [])
let send_switch st dpid msg =
  try_lwt 
    let ch = Hashtbl.find st.switches dpid in 
      OC.send_data ch dpid msg
  with Not_found -> return (cp (sp "[flowvisor] unregister dpid %Ld\n%!" dpid))

let send_controller t msg =  OSK.send_packet t msg
let inform_controllers flv m msg =  
  (* find the controller that should handle the packet in *)
    Lwt_list.iter_p
    (fun (_, rule, t) ->
      if (OP.Match.flow_match_compare rule m rule.OP.Match.wildcards) then
        Openflow.Ofsocket.send_packet t msg
      else return ()) flv.controllers 

(*************************************************
* Switch OpenFlow control channel 
 *************************************************)
let packet_out_create st msg xid inp bid data actions =
  let data = 
    match (bid) with
    | -1l -> data
      (* if no buffer id included, send the data section of the
       * packet_out*)
   | bid when (Hashtbl.mem st.buffer_id_map bid) -> 
        (* if we have a buffer id in cache, use those data *)
        let (pkt, _ ) = Hashtbl.find st.buffer_id_map bid in
        let _ = Hashtbl.remove st.buffer_id_map bid in 
          pkt.OP.Packet_in.data
   | _ -> raise (Ofcontroller_error(xid, OP.REQUEST_BUFFER_UNKNOWN, msg) )
  in 
  let in_port = port_of_port st inp in  
  let m = OP.Packet_out.create ~buffer_id:(-1l) 
      ~actions ~in_port ~data () in
  let h = OP.Header.(create ~xid PACKET_OUT 0) in 
  OP.Packet_out (h,m)  
 
 let rec pkt_out_process st xid inp bid data msg acts = function
  | (OP.Flow.Output(OP.Port.All, len))::tail 
  | (OP.Flow.Output(OP.Port.Flood, len))::tail -> begin
    let actions = acts @  [OP.Flow.Output(OP.Port.Flood, len)] in
    (* OP.Port.None is not the appropriate way to handle this. Need to find the
     * port that connects the two switches probably. *)
    let in_dpid = dpid_of_port st inp in    
(*    let _ = pp "sending packet from port %d to port %d\n%!"
 *    (OP.Port.int_of_port inp) (in_p) in  *)
    let msg = packet_out_create st msg xid OP.Port.No_port (-1l) data actions in
    lwt _ =
      Lwt_list.iter_p (
        fun (dpid, ch) -> 
          if (dpid = in_dpid) then
            OC.send_data ch dpid  
              (packet_out_create st msg xid inp (-1l) data actions) 
          else
            OC.send_data ch dpid msg
        ) (Hashtbl.fold (fun dpid ch c -> c @[(dpid, ch)]) st.switches []) in 
      pkt_out_process st xid inp bid data msg acts tail 
  end
  | (OP.Flow.Output(OP.Port.In_port, len))::tail -> begin
    (* output packet to the last hop of the path *)
    let (dpid, out_p)  = dpid_port_of_port_exn st inp xid msg in  
    let actions = acts @  [OP.Flow.Output(OP.Port.In_port, len)] in
    lwt _ = send_switch st dpid 
      (packet_out_create st msg xid out_p bid data actions) in
      pkt_out_process st xid inp bid data msg acts tail 
   end
 | (OP.Flow.Output(OP.Port.Port(p), len))::tail -> begin
    (* output packet to the last hop of the path *)
    let (dpid, out_p)  = dpid_port_of_port_exn st (to_port p) xid msg  in 
    let actions = acts @  [OP.Flow.Output(out_p, len)] in
    let msg = packet_out_create st msg xid inp bid data actions in 
    lwt _ = send_switch st dpid
      (packet_out_create st msg xid inp bid data actions) in 
    pkt_out_process st xid inp bid data msg acts tail 
    end
  | (OP.Flow.Output(OP.Port.Controller, len))::tail 
  | (OP.Flow.Output(OP.Port.Table, len))::tail 
  | (OP.Flow.Output(OP.Port.Local, len))::tail 
  | (OP.Flow.Output(OP.Port.No_port, len))::tail 
  | (OP.Flow.Output(OP.Port.Normal, len))::tail -> 
      raise (Ofcontroller_error (xid, OP.REQUEST_BAD_STAT, msg) )
  | a :: tail -> 
      (* for the non-output action, populate the new action list *)
      pkt_out_process st xid inp bid data msg (acts @ [a]) tail 
  | [] -> return ()

let map_path flv in_dpid in_port out_dpid out_port =
(*  let _ = pp "[flowvisor-switch] mapping a path between %Ld:%s - %Ld:%s\n%!" 
            in_dpid (OP.Port.string_of_port in_port) 
            out_dpid (OP.Port.string_of_port out_port) in *)
  if (in_dpid = out_dpid) then [(out_dpid, in_port, out_port)]
  else
    Flowvisor_topology.find_dpid_path flv.flv_topo 
      in_dpid in_port out_dpid out_port 
(*      let path = List.rev path in *)
(*      let _ = 
        List.iter (
          fun (dp, in_p, out_p) ->
            pp "%s:%Ld:%s -> " 
            (OP.Port.string_of_port in_p)
            dp (OP.Port.string_of_port out_p)
        ) path in 
      let _ = pp "\n%!" in 
      path  *)

(* TODO fixme!!!! *)
let map_spanning_tree flv in_dpid in_port = []

let rec send_flow_mod_to_path st xid msg pkt len actions path =
  let h = OP.Header.create ~xid OP.Header.FLOW_MOD 0 in 
  match path with
  | [] -> return ()
  | [(dpid, in_port, out_port)] -> begin 
    let actions = actions @  [OP.Flow.Output(out_port, len)] in
    let _ = pkt.of_match.in_port <- in_port in 
    let fm = OP.Flow_mod.(
      {pkt with buffer_id=(-1l);out_port=(OP.Port.No_port);actions;}) in 
    lwt _ = send_switch st dpid (OP.Flow_mod(h, fm)) in 
    match (pkt.buffer_id) with
    | -1l -> return ()
    | bid when (Hashtbl.mem st.buffer_id_map bid) -> 
      (* if we have a buffer id in cache, use those data *)
      let (pkt, _ ) = Hashtbl.find st.buffer_id_map bid in  
      let msg = packet_out_create st msg xid (OP.Port.No_port) 
          (-1l) (pkt.OP.Packet_in.data) actions in 
      lwt _ = send_switch st dpid msg in
      return ()
    | _ -> 
      (* if buffer id is unknown, send error *)
      raise (Ofcontroller_error(xid, OP.REQUEST_BUFFER_UNKNOWN, msg))
  end
  | ((dpid, in_port, out_port)::rest) -> begin 
    let _ = pkt.of_match.in_port <- in_port in 
    let fm = OP.Flow_mod.(
      {pkt with buffer_id=(-1l);out_port=(OP.Port.No_port);
      actions=( [OP.Flow.Output(out_port, len)] );}) in
    lwt _ = send_switch st dpid (OP.Flow_mod(h, fm)) in 
      send_flow_mod_to_path st xid msg pkt len actions rest       
  end

let rec flow_mod_translate_inner st msg xid pkt in_dpid in_port acts = function
  | (OP.Flow.Output(OP.Port.All, len))::tail 
  | (OP.Flow.Output(OP.Port.Flood, len))::tail ->
      (* Need a spanning tree maybe for this? *)
      lwt _ = send_flow_mod_to_path st xid msg pkt len acts 
              (map_spanning_tree st in_dpid in_port) in
        flow_mod_translate_inner st msg xid pkt in_dpid in_port acts tail 
  | (OP.Flow.Output(OP.Port.In_port, len))::tail -> 
      lwt _ = send_flow_mod_to_path st xid msg pkt len acts 
                [(in_dpid, OP.Port.Port(in_port), OP.Port.In_port)] in
        flow_mod_translate_inner st msg xid pkt in_dpid in_port acts tail 
  | (OP.Flow.Output(OP.Port.Controller, len))::tail -> 
      lwt _ = send_flow_mod_to_path st xid msg pkt len acts 
              [(in_dpid, OP.Port.Port(in_port), OP.Port.Controller)] in 
        flow_mod_translate_inner st msg xid pkt in_dpid in_port acts tail 
  | (OP.Flow.Output(OP.Port.Port(p), len))::tail ->
      let (out_dpid, out_port) = dpid_port_of_port_exn st (to_port p) xid msg in 
      lwt _ = send_flow_mod_to_path st xid msg pkt len acts 
              (map_path st in_dpid (OP.Port.Port(in_port) )
              out_dpid out_port) in
      flow_mod_translate_inner st msg xid pkt in_dpid in_port acts tail 
  | (OP.Flow.Output(OP.Port.Table, _))::_
  | (OP.Flow.Output(OP.Port.Local, _))::_
  | (OP.Flow.Output(OP.Port.Normal, _))::_ -> 
      raise (Ofcontroller_error (xid, OP.REQUEST_BAD_STAT, msg) )
  | a :: tail -> flow_mod_translate_inner st msg xid pkt in_dpid in_port (acts@[a]) tail 
  | [] -> return ()

let flow_mod_add_translate st msg xid pkt = 
  let (in_dpid, in_port) = dpid_port_of_port_exn st pkt.of_match.in_port xid msg in
   flow_mod_translate_inner st msg xid pkt in_dpid (of_port in_port) [] pkt.actions
 
let flow_mod_del_translate st msg xid pkt =
  match (pkt.of_match.OP.Match.wildcards.OP.Wildcards.in_port,  
        pkt.of_match.OP.Match.in_port, pkt.OP.Flow_mod.out_port) with
  | (false, OP.Port.Local, OP.Port.No_port) 
  | (true, _, OP.Port.No_port) ->
      let h = OP.Header.(create ~xid FLOW_MOD 0) in 
      send_all_switches st (OP.Flow_mod(h, pkt))
  | (false, OP.Port.Port(p), OP.Port.No_port) ->  
      let (dpid, port) = dpid_port_of_port_exn st (to_port p) xid msg in 
      let _ = pkt.of_match.in_port <- port in 
      let h = OP.Header.(create ~xid FLOW_MOD 0) in 
      send_switch st dpid (OP.Flow_mod(h, pkt))
  | (false, OP.Port.Port(in_p), OP.Port.Port(out_p)) ->  
      let (in_dpid, in_port) = dpid_port_of_port_exn st
          pkt.of_match.OP.Match.in_port xid msg in 
      let (out_dpid, out_port) =  dpid_port_of_port_exn st
          pkt.OP.Flow_mod.out_port xid msg in 
      lwt _ = send_flow_mod_to_path st xid msg pkt 0 [] 
              (map_path st in_dpid in_port out_dpid out_port) in
        return ()
  | _ -> raise (Ofcontroller_error (xid, OP.REQUEST_BAD_STAT, msg) )
  
let process_openflow st dpid t msg =
  let _ = if st.verbose then cp (sp "[flowvisor-switch] %s\n%!" (OP.to_string msg)) in 
  match msg with
  | OP.Hello (h) -> return ()
  | OP.Echo_req (h) -> (* Reply to ECHO requests *)
      let open OP.Header in 
      send_controller t (OP.Echo_resp (create ECHO_RESP ~xid:h.xid get_len))
  | OP.Features_req (h)  -> 
      let h = OP.Header.(create FEATURES_RESP ~xid:h.xid 0) in
      let f = switch_features dpid 
                (Hashtbl.fold (fun _ (_, _, p) r -> p::r) 
                st.port_map []) in  
    send_controller t (OP.Features_resp(h, f))
  | OP.Stats_req(h, req) -> begin
      (* TODO Need to translate the xid here *)
    match req with
    | OP.Stats.Desc_req(req) ->
      let open OP.Stats in 
      let desc = { imfr_desc="Mirage"; hw_desc="Mirage";
        sw_desc="Mirage_flowvisor"; serial_num="0.1";
        dp_desc="Mirage";} in
      let resp_h = {st_ty=DESC;more=false;} in
      send_controller t
          (OP.Stats_resp(h, (Desc_resp(resp_h,desc)))) 
    | OP.Stats.Flow_req(req_h, of_match, table_id, out_port) -> begin
      (*TODO Need to consider the  table_id and the out_port and 
       * split reply over multiple openflow packets if they don't
       * fit a single packet. *)
        match (of_match.OP.Match.wildcards.OP.Wildcards.in_port,  
               (of_match.OP.Match.in_port)) with
        | (false, OP.Port.Port(p)) ->
          let (dst_dpid, out_port) = dpid_port_of_port_exn st
              of_match.OP.Match.in_port h.OP.Header.xid msg in
          let xid = get_new_xid h.OP.Header.xid st dst_dpid [dpid] (Flows [])in 
          let h = OP.Header.(create STATS_RESP ~xid 0) in
          let of_match = OP.Match.translate_port of_match out_port in 
          (* TODO out_port needs processing. if dpid are between 
           * different switches need to define the outport 
             * as the port of the interconnection link *)
          let req = OP.Stats.(
              Flow_req(req_h, of_match, table_id, out_port)) in
          send_switch st dst_dpid (OP.Stats_req(h, req)) 
        | (_, _) -> 
          let req = OP.Stats.(Flow_req(req_h, of_match,table_id, out_port)) in
          let xid = get_new_xid h.OP.Header.xid st dpid (switch_dpid st) (Flows []) in 
          let h = OP.Header.(create STATS_RESP ~xid 0) in
          send_all_switches st (OP.Stats_req(h, req))
     end
    | OP.Stats.Aggregate_req (req_h, of_match, table_id, out_port) -> 
      begin
        let open OP.Stats in
        let open OP.Header in 
        let cache = Aggr ({packet_count=0L; byte_count=0L;flow_count=0l;}) in 
        match OP.Match.(of_match.wildcards.OP.Wildcards.in_port,(of_match.in_port)) with
        | (false, OP.Port.Port(p)) ->
          let (dst_dpid, port) = dpid_port_of_port_exn st of_match.in_port h.xid msg in 
          let xid = get_new_xid h.xid st dpid [dst_dpid] cache in 
          let h = { h with xid;} in
          let _ = of_match.in_port <- port in 
          (* TODO out_port needs processing. if dpid are between 
           * different switches need to define the outport as the 
           * port of the interconnection link *)
          let m = Aggregate_req(req_h, of_match, table_id, out_port) in
          send_switch st dst_dpid (OP.Stats_req(h, m))
       | (_, _) ->
         let open OP.Header in 
         let h = {h with xid=(get_new_xid h.xid st dpid
                                (switch_dpid st) cache);} in
            send_all_switches st  (OP.Stats_req(h, req))
     end
    | OP.Stats.Table_req(req_h) ->
        let open OP.Header in 
        let cache = Table OP.Stats.(init_table_stats (OP.Stats.table_id_of_int 1) 
                    "mirage" (OP.Wildcards.full_wildcard ()) ) in 
        let xid = get_new_xid h.xid st dpid (switch_dpid st) cache in 
        let h = {h with xid;} in
        send_all_switches st (OP.Stats_req(h, req))
    | OP.Stats.Port_req(req_h, port) -> begin
      match port with
      | OP.Port.No_port -> 
        let open OP.Header in 
        let xid = get_new_xid h.xid st dpid (switch_dpid st) (Port []) in 
        let h = ({h with xid;}) in  
        send_all_switches st (OP.Stats_req(h, req))
      | OP.Port.Port(_) -> 
        let open OP.Header in 
        let (dst_dpid, port) = dpid_port_of_port_exn st port h.xid msg in 
        let xid = get_new_xid h.xid st dpid [dst_dpid] (Port []) in 
        let h = {h with xid;} in
        let m = OP.Stats.(Port_req(req_h, port)) in
        send_all_switches st (OP.Stats_req(h, m)) 
      | _ ->
          raise (Ofcontroller_error (h.OP.Header.xid, OP.QUEUE_OP_BAD_PORT, msg)) 
      end
    | _ ->
        raise (Ofcontroller_error (h.OP.Header.xid, OP.REQUEST_BAD_STAT, msg)) 
   end
  | OP.Get_config_req(h) ->
      (* TODO make a custom reply tothe query *) 
      let h = OP.Header.({h with  ty=GET_CONFIG_RESP}) in
        send_controller t (OP.Get_config_resp(h, (OP.Switch.init_switch_config
        3000) ))
  | OP.Barrier_req(h) ->
      (* TODO just reply for now. need to check this with all switches *)
(*       let xid = get_new_xid dpid in  *)
      let _ = cp (sp "BARRIER_REQ: %s\n%!" (OP.Header.header_to_string h)) in
      send_controller t (OP.Barrier_resp (OP.Header.({h with ty=BARRIER_RESP;})) )
  | OP.Packet_out(h, pkt) -> begin
    let _ = if st.verbose then cp (sp "[flowvisor-switch] PACKET_OUT: %s\n%!" 
            (OP.Packet_out.packet_out_to_string pkt)) in
    (* Check if controller has the right to send traffic on the specific subnet *)
    try_lwt
      OP.Packet_out.(pkt_out_process st h.OP.Header.xid pkt.in_port
                      pkt.buffer_id pkt.data  msg [] pkt.actions )
    with exn -> 
      return (cp (sp "[flowvisor-switch] packet_out message error %s\n%!"
        (Printexc.to_string exn)))
  end
  | OP.Flow_mod(h,fm)  -> begin
    let _ =  if st.verbose then cp (sp "[flowvisor-switch] FLOW_MOD: %s\n%!"
            (OP.Flow_mod.flow_mod_to_string fm)) in 
    let xid = get_new_xid h.OP.Header.xid st dpid (switch_dpid st) No_reply in 
         match (fm.OP.Flow_mod.command) with
          | OP.Flow_mod.ADD 
          | OP.Flow_mod.MODIFY 
          | OP.Flow_mod.MODIFY_STRICT -> 
              flow_mod_add_translate st msg xid fm
          | OP.Flow_mod.DELETE 
          | OP.Flow_mod.DELETE_STRICT ->
              flow_mod_del_translate st msg xid fm 
  end
  (*Unsupported switch actions *)
  | OP.Set_config (h, _) -> return () 
  | OP.Port_mod (h, _)
  | OP.Queue_get_config_resp (h, _, _)
  | OP.Queue_get_config_req (h, _)
  (* Message that should not be received by a switch *)
  | OP.Port_status (h, _)
  | OP.Flow_removed (h, _)
  | OP.Packet_in (h, _)
  | OP.Get_config_resp (h, _)
  | OP.Barrier_resp h
  | OP.Stats_resp (h, _)
  | OP.Features_resp (h, _)
  | OP.Vendor (h, _)
  | OP.Echo_resp (h)
  | OP.Error (h, _, _) ->
      let h = OP.Header.(create ~xid:h.xid OP.Header.ERROR 0) in 
      let bits = OP.marshal msg in  
        send_controller t (OP.Error(h, OP.REQUEST_BAD_TYPE, bits) )

let switch_channel st dpid of_m sock =
  let h = OP.Header.(create ~xid:1l HELLO sizeof_ofp_header) in
  lwt _ = Openflow.Ofsocket.send_packet sock (OP.Hello h) in  
  let _ = st.controllers <- (dpid, of_m, sock)::st.controllers in
  let continue = ref true in 
    while_lwt !continue do 
      try_lwt
        lwt ofp = Openflow.Ofsocket.read_packet sock in
          process_openflow st dpid sock ofp 
      with
        | Nettypes.Closed -> 
            let _ = continue := false in 
            return (cp (sp "[flowvisor-switch] control channel closed\n%!") )
        | OP.Unparsed (m, bs) -> 
            return (cp (sp "[flowvisor-switch] # unparsed! m=%s\n %!" m))
        | Ofcontroller_error (xid, error, msg)->
          let h = OP.Header.create ~xid OP.Header.ERROR 0 in 
            send_switch st dpid (OP.Error(h, error, (OP.marshal msg))) 
        | exn -> return (cp (sp "[flowvisor-switch] ERROR:%s\n"
                               (Printexc.to_string exn))) 
    done

(*
 * openflow controller threads 
 * *)
let add_flowvisor_port flv dpid port =
  let port_id = flv.portnum in 
  let _ = flv.portnum <- flv.portnum + 1 in
  let phy = OP.Port.translate_port_phy port port_id in
  let _ = Hashtbl.add flv.port_map port_id 
            (dpid, port.OP.Port.port_no, phy) in 
  lwt _ = Flowvisor_topology.add_port flv.flv_topo dpid port.OP.Port.port_no
        port.OP.Port.hw_addr in 
  let h = OP.Header.(create PORT_STATUS 0 ) in 
  let status = OP.Port_status(h, (OP.Port.({reason=OP.Port.ADD; desc=phy;}))) in 
    Lwt_list.iter_p 
    (fun (dpid, _, conn) -> 
      Openflow.Ofsocket.send_packet conn status ) flv.controllers

(*
 * openflow controller threads 
 **)
let del_flowvisor_port flv desc =
  let h = OP.Header.(create PORT_STATUS 0 ) in 
  let status = OP.Port_status(h, (OP.Port.({reason=OP.Port.ADD;desc;}))) in
    Lwt_list.iter_p 
    (fun (dpid, _, conn) -> 
      Openflow.Ofsocket.send_packet conn status ) flv.controllers

let map_flv_port flv dpid port = 
  (* map the new port *)
  let p = 
      Hashtbl.fold (
        fun flv_port (sw_dpid, sw_port, _) r -> 
          if ((dpid = sw_dpid) && 
              (sw_port = port)) then flv_port
          else r ) flv.port_map (-1) in
  if (p < 0) then  OP.Port.Port(port)
  else OP.Port.Port (p)

let translate_stat flv dpid f = 
  (* Translate match *)
  let _ = 
    match (f.OP.Flow.of_match.OP.Match.wildcards.OP.Wildcards.in_port,
            f.OP.Flow.of_match.OP.Match.in_port) with
    | (false, OP.Port.Port(p) ) -> 
      f.OP.Flow.of_match.OP.Match.in_port <- map_flv_port flv dpid p
    | _ -> ()
  in

  let _ = 
    f.OP.Flow.action <- List.map 
    (fun act -> 
    match act with
    | OP.Flow.Output(OP.Port.Port(p), len ) -> 
      let p = map_flv_port flv dpid p in 
      OP.Flow.Output(p, len )
    | _ -> act) f.OP.Flow.action in 
  (* Translate actions *)
  f

let process_switch_channel flv st dpid e =
  try_lwt
    let _ = if (flv.verbose) then cp (sp "[flowvisor-ctrl] %s\n%!" (OE.string_of_event e)) in 
    match e with 
    | OE.Datapath_join(dpid, ports) ->
      let _ = cp (sp "[flowvisor-ctrl]+ switch dpid:%Ld\n%!" dpid) in 
      let _ = Flowvisor_topology.add_channel flv.flv_topo dpid st in 
      (* Update local state  and send new ports to all connected controllers *)
      let _ = Hashtbl.replace flv.switches dpid st in 
      lwt _ = OC.send_data st dpid 
          OP.(Set_config( (OP.Header.(create SET_CONFIG 0),
          OP.Switch.(init_switch_config 0x1fff)))) in
      Lwt_list.iter_p (add_flowvisor_port flv dpid) ports
    | OE.Datapath_leave(dpid) ->
      let _ = (cp(sp "[flowvisor-ctrl]- switch dpid:%Ld\n%!" dpid)) in 
      let _ = Flowvisor_topology.remove_dpid flv.flv_topo dpid in 
      (* Need to remove ports and port mapping and discard any state 
       * pending for replies. *)
      Lwt_list.iter_p (del_flowvisor_port flv) 
        ( Hashtbl.fold (fun vp (dp, _, phy) r -> 
             if (dp = dpid) then 
               let _ = Hashtbl.remove flv.port_map vp in
               phy::r else r) flv.port_map [])
    | OE.Packet_in(in_port, reason, buffer_id, data, dpid) -> begin
        let m = OP.Match.raw_packet_to_match in_port data in
        let _ = (cp(sp "[flowvisor-ctrl] type:PACKET_IN dpid:%08Ld %s\n%!"
                      dpid (OP.Match.match_to_string m) )) in

        (* Handle packet appropriately *)
        match (in_port, m.OP.Match.dl_type) with 
        | (OP.Port.Port(p), 0x88cc) -> begin
          (* LLDP is used to infer the topology of the network *)
            match (Flowvisor_topology.process_lldp_packet 
                     flv.flv_topo dpid p data) with
            | true -> return ()
            | false ->
              let in_port = map_flv_port flv dpid p in
              let h = OP.Header.(create PACKET_IN 0) in 
              let pkt = OP.Packet_in.({buffer_id=(-1l);in_port;reason;data;}) in 
              inform_controllers flv m (OP.Packet_in(h, pkt)) 
          end
        | (OP.Port.Port(p), _) when 
            not (Flowvisor_topology.is_transit_port flv.flv_topo dpid p) -> begin
            (* translate the buffer id information *)
            let buffer_id = flv.buffer_id_count in 
            flv.buffer_id_count <- Int32.succ flv.buffer_id_count;

            (* generate packet bits *)
            let in_port = map_flv_port flv dpid p in
            let h = OP.Header.(create PACKET_IN 0) in 
            let pkt = OP.Packet_in.({buffer_id;in_port;reason;data;}) in 
            let _ = Hashtbl.add flv.buffer_id_map buffer_id (pkt, dpid) in
            inform_controllers flv m (OP.Packet_in(h, pkt)) 
          end 
        | (OP.Port.Port(p), _) -> return ()
        | _ -> 
          let _ = cp (sp "[flowvisor-ctrl] Invalid Packet_in port\n%!") in
          let h = OP.Header.(create ERROR 0) in 
          inform_controllers flv m 
            (OP.Error(h, OP.REQUEST_BAD_STAT, (Cstruct.create 0))) 
      end
    | OE.Flow_removed(of_match, r, dur_s, dur_ns, pkts, bytes, dpid)  ->
      (* translate packet  TODO need to pass cookie id, idle, and priority *)
      let _ = of_match.OP.Match.in_port <-
        map_flv_port flv dpid (of_port of_match.OP.Match.in_port) in 
      let pkt = 
        OP.Flow_removed.(
          {of_match; cookie=0L;reason=r; priority=0;idle_timeout=0;  
           duration_sec=dur_s; duration_nsec=dur_ns; packet_count=pkts;
           byte_count=bytes;}) in
      let h = OP.Header.(create FLOW_REMOVED 0) in 
      inform_controllers flv of_match  (OP.Flow_removed(h, pkt))
    (* TODO: Need to write code to handle stats replies *)
    | OE.Flow_stats_reply(xid, more, flows, dpid) -> begin
        if Hashtbl.mem flv.xid_map xid then (
          let xid_st = Hashtbl.find flv.xid_map xid in
          match xid_st.cache with
          | Flows fl -> 
            (* Group reply separation *)
            xid_st.cache <- (Flows (fl @ flows));
            let flows = List.map (translate_stat flv dpid) flows in 
            let _ = 
              if not more then 
                xid_st.dst <- List.filter (fun a -> a <> dpid) xid_st.dst 
            in
            if (List.length xid_st.dst = 0 ) then 
              let _ = Hashtbl.remove flv.xid_map xid in 
              handle_xid flv st xid_st
            else
              return (Hashtbl.replace flv.xid_map xid xid_st)
          | _ -> return ()
        ) else  
          return (cp (sp "[flowvisor-ctrl] Unknown stats reply xid\n%!"))
      end
    | OE.Aggr_flow_stats_reply(xid, pkts, bytes, flows, dpid) -> begin
        if (Hashtbl.mem flv.xid_map xid) then ( 
          let xid_st = Hashtbl.find flv.xid_map xid in 
          match xid_st.cache with
          | Aggr aggr -> 
            (* Group reply separation *)
            let aggr = 
              OP.Stats.({packet_count=(Int64.add pkts aggr.packet_count);
                         byte_count=(Int64.add bytes aggr.byte_count);
                         flow_count=(Int32.add flows aggr.flow_count);}) in
            let _ = xid_st.cache <- (Aggr aggr) in 
            let _ = 
              xid_st.dst <- List.filter (fun a -> a <> dpid) xid_st.dst
            in 
            if (List.length xid_st.dst = 0 ) then 
              let _ = Hashtbl.remove flv.xid_map xid in 
              handle_xid flv st xid_st
            else 
              return (Hashtbl.replace flv.xid_map xid xid_st)
          | _ -> return ()
        ) else return ()
      end
    | OE.Port_stats_reply(xid, more, ports, dpid) ->  begin
        if (Hashtbl.mem flv.xid_map xid) then ( 
          let xid_st = Hashtbl.find flv.xid_map xid in 
          match xid_st.cache with
          | Port p -> 
            (* Group reply separation *)
            let ports = List.map (fun port -> 
                let port_id = map_flv_port flv dpid port.OP.Port.port_id in 
                OP.Port.({port with port_id=(OP.Port.int_of_port port_id);})) ports in 
            let _ = xid_st.cache <- (Port (p @ ports)) in 
            let _ = if not more then 
                xid_st.dst <- List.filter (fun a -> a <> dpid) xid_st.dst in 
            if (List.length xid_st.dst = 0 ) then
              let _ = Hashtbl.remove flv.xid_map xid in 
              handle_xid flv st xid_st
            else 
              let _ = Hashtbl.replace flv.xid_map xid xid_st in
              return ()
          | _ -> return ()
        ) else return ()
      end
    | OE.Table_stats_reply(xid, more, tables, dpid) -> 
      return ()
    | OE.Port_status(reason, port, dpid) -> 
      (* TODO: send a port withdrawal to all controllers *)
      add_flowvisor_port flv dpid port
    | _ -> return (cp "[flowvisor-ctrl] Unsupported event\n%!")
  with Not_found -> return (cp(sp "[flowvisor-ctrl] ignore pkt of non existing state\n%!"))

  let init flv st = 
    (* register all the required handlers *)
    let fn = process_switch_channel flv in 
    OC.register_cb st OE.DATAPATH_JOIN fn;
    OC.register_cb st OE.DATAPATH_LEAVE fn;
    OC.register_cb st OE.PACKET_IN fn;
    OC.register_cb st OE.FLOW_REMOVED fn;
    OC.register_cb st OE.FLOW_STATS_REPLY fn;
    OC.register_cb st OE.AGGR_FLOW_STATS_REPLY fn;
    OC.register_cb st OE.PORT_STATUS_CHANGE fn;  
    OC.register_cb st OE.TABLE_STATS_REPLY fn 

let create_flowvisor ?(verbose=false) () =
  let ret = init_flowvisor verbose (Flowvisor_topology.init_topology ()) in 
  let _ = ignore_result (Flowvisor_topology.discover ret.flv_topo) in
  ret

let add_slice mgr flv of_m dst dpid =
  ignore_result ( 
    while_lwt true do
      let switch_connect (addr, port) t = 
        let rs = Ipaddr.V4.to_string addr in
        try_lwt 
          let _ = cp (sp "[flowvisor-switch]+ switch %s:%d\n%!" rs port) in 
          (* Trigger the dance between the 2 nodes *)
          let sock = Openflow.Ofsocket.init_socket_conn_state t in
          switch_channel flv dpid of_m sock
        with exn -> 
          return (cp(sp "[flowvisorswitch]- switch %s:%d %s\n%!" rs port (Printexc.to_string exn)))
      in
      Net.Channel.connect mgr ( `TCPv4 (None, dst, (switch_connect dst) ) )
    done)  

let listen st mgr loc = OC.listen mgr loc (init st) 
let local_listen st conn = OC.local_connect (OC.init_controller (init st)) conn 

let remove_slice _ _ = ()
let add_local_slice flv of_m  conn dpid = ignore_result ( switch_channel flv dpid of_m conn)  
    (* TODO Need to store thread for termination on remove_slice *)
