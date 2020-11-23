module Url : sig
  type t = Git of { repo : string; ref : string option } | Other of string

  (* This includes archives, other VCS and rsync opam src URLs *)

  val equal : t -> t -> bool

  val pp : t Fmt.t

  val from_opam : OpamFile.URL.t -> t
end

module Package_summary : sig
  type t = { name : string; version : string; url_src : Url.t option; dev_repo : string option }

  val equal : t -> t -> bool

  val pp : t Fmt.t

  val from_opam : pkg:OpamPackage.t -> OpamFile.OPAM.t -> t

  val is_virtual : t -> bool
  (** A package is considered virtual if it has no url.src or no dev-repo. *)

  val is_base_package : t -> bool
end

module Pp : sig
  val package : OpamPackage.t Fmt.t
end

val depends_on_dune : OpamTypes.filtered_formula -> bool
(** Returns whether the given depends field formula contains a dependency to dune or jbuilder *)

val pull_tree :
  url:OpamUrl.t ->
  dir:Fpath.t ->
  OpamStateTypes.unlocked OpamStateTypes.global_state ->
  (unit, [ `Msg of string ]) result
(** Pulls the sources from [url] to [dir] using opam's library.
    This benefits from opam's global cache *)
