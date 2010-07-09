(* Ocsigen
 * http://www.ocsigen.org
 * Module server.ml
 * Copyright (C) 2010
 * Raphaël Proust
 * Laboratoire PPS - CNRS Université Paris Diderot
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(** [Eliom_event] is a module that allow one to use propagate events occurrences
    from the server to the client and the other way around. It is to be noted
    that occurrence propagation is done asynchronously.

    The use of this module is pretty much useless without it's client counter
    part: [Eliom_client_event]. These two dual files are to be modified together
    with compatibility issues in mind. *)


module Down :
  (** A "Down event" is an event which occurrences are transmitted
      asynchronously to the client. The return type of the [wrap]ing function
      gives insight about how Down events are handled internally, it is however
      taken care of automatically. *)
sig

  val wrap :
      sp:Eliom_sessions.server_params
    -> 'a React.E.t
    -> 'a Eliom_common_comet.buffered_chan_id Eliom_client_types.data_key
  (** [wrap ~sp e] wraps the event [e] so that it can be handed to the client.
    *)

end

module Up :
  (** Up events are quite different from Down events. Because of the
      asymmetrical nature of web programming and because of the reactive model
      used, an Up event must be created on the server and wrapped into a
      callback (or something the client can build a callback with). *)
sig

  type 'a event
  (** The type of events going up from the client to the server. On the server
      such an event is /primitive/ (hence the [create] function) whereas it is
      /effectful/ on the client. *)

  val react_event_of_up_event : 'a event -> 'a React.E.t
  (** [react_event_of_up_event e] injects up events into events so that it can
      be manipulated as a standard event. *)

  val wrap :
      sp:Eliom_sessions.server_params
    -> 'a event
    -> (unit, 'a, [ `Nonattached of [ `Post ] Eliom_services.na_s ],
        [ `WithoutSuffix ], unit, [`One of 'a] Eliom_parameters.param_name,
        [ `Registrable ], Eliom_predefmod.Action.return)
         Eliom_services.service Eliom_client_types.data_key
  (** [wrap e] wraps [e] into a wrapped service. This result is to be handled by
      the [Eliom_client_event.Up.unwrap] function. *)

  val create :
       ?sp:Eliom_sessions.server_params
    -> ('a, [ `WithoutSuffix ], [`One of 'a ] Eliom_parameters.param_name)
         Eliom_parameters.params_type
    -> 'a event
  (** [create ?sp param] creates an Up event. [?sp] has to be set to [Some _]
      if the event is created dynamically. *)

end