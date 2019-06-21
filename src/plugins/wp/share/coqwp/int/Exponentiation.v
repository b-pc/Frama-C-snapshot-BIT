(**************************************************************************)
(*                                                                        *)
(*  The Why3 Verification Platform   /   The Why3 Development Team        *)
(*  Copyright 2010-2019   --   Inria - CNRS - Paris-Sud University        *)
(*                                                                        *)
(*  This software is distributed under the terms of the GNU Lesser        *)
(*  General Public License version 2.1, with the special exception        *)
(*  on linking described in file LICENSE.                                 *)
(*                                                                        *)
(**************************************************************************)

(* This file is generated by Why3's Coq-realize driver *)
(* Beware! Only edit allowed sections below    *)
Require Import BuiltIn.
Require BuiltIn.
Require int.Int.

Section Exponentiation.

(* Why3 goal *)
Variable t : Type.
Hypothesis t_WhyType : WhyType t.
Existing Instance t_WhyType.

(* Why3 goal *)
Variable one: t.

(* Why3 goal *)
Variable infix_as: t -> t -> t.

(* Why3 goal *)
Hypothesis Assoc :
  forall (x:t) (y:t) (z:t),
  ((infix_as (infix_as x y) z) = (infix_as x (infix_as y z))).

(* Why3 goal *)
Hypothesis Unit_def_l : forall (x:t), ((infix_as one x) = x).

(* Why3 goal *)
Hypothesis Unit_def_r : forall (x:t), ((infix_as x one) = x).

(* Why3 goal *)
Definition power : t -> Z -> t.
intros x n.
exact (iter_nat (Zabs_nat n) t (fun acc => infix_as x acc) one).
Defined.

(* Why3 goal *)
Lemma Power_0 : forall (x:t), ((power x 0%Z) = one).
Proof.
easy.
Qed.

(* Why3 goal *)
Lemma Power_s :
  forall (x:t) (n:Z), (0%Z <= n)%Z ->
  ((power x (n + 1%Z)%Z) = (infix_as x (power x n))).
Proof.
intros x n h1.
unfold power.
fold (Zsucc n).
now rewrite Zabs_nat_Zsucc.
Qed.

(* Why3 goal *)
Lemma Power_s_alt :
  forall (x:t) (n:Z), (0%Z < n)%Z ->
  ((power x n) = (infix_as x (power x (n - 1%Z)%Z))).
Proof.
intros x n h1.
rewrite <- Power_s; auto with zarith.
f_equal; omega.
Qed.

(* Why3 goal *)
Lemma Power_1 : forall (x:t), ((power x 1%Z) = x).
Proof.
exact Unit_def_r.
Qed.

(* Why3 goal *)
Lemma Power_sum :
  forall (x:t) (n:Z) (m:Z), (0%Z <= n)%Z -> (0%Z <= m)%Z ->
  ((power x (n + m)%Z) = (infix_as (power x n) (power x m))).
Proof.
intros x n m Hn Hm.
revert n Hn.
apply natlike_ind.
apply sym_eq, Unit_def_l.
intros n Hn IHn.
replace (Zsucc n + m)%Z with ((n + m) + 1)%Z by ring.
rewrite Power_s by auto with zarith.
rewrite IHn.
now rewrite <- Assoc, <- Power_s.
Qed.

(* Why3 goal *)
Lemma Power_mult :
  forall (x:t) (n:Z) (m:Z), (0%Z <= n)%Z -> (0%Z <= m)%Z ->
  ((power x (n * m)%Z) = (power (power x n) m)).
Proof.
intros x n m Hn Hm.
revert m Hm.
apply natlike_ind.
now rewrite Zmult_0_r, 2!Power_0.
intros m Hm IHm.
replace (n * Zsucc m)%Z with (n + n * m)%Z by ring.
rewrite Power_sum by auto with zarith.
rewrite IHm.
now rewrite <- Power_s.
Qed.

(* Why3 goal *)
Lemma Power_comm1 :
  forall (x:t) (y:t), ((infix_as x y) = (infix_as y x)) -> forall (n:Z),
  (0%Z <= n)%Z -> ((infix_as (power x n) y) = (infix_as y (power x n))).
Proof.
intros x y comm.
apply natlike_ind.
now rewrite Power_0, Unit_def_r, Unit_def_l.
intros n Hn IHn.
unfold Zsucc.
rewrite (Power_s _ _ Hn).
rewrite Assoc.
rewrite IHn.
rewrite <- Assoc.
rewrite <- Assoc.
now rewrite comm.
Qed.

(* Why3 goal *)
Lemma Power_comm2 :
  forall (x:t) (y:t), ((infix_as x y) = (infix_as y x)) -> forall (n:Z),
  (0%Z <= n)%Z ->
  ((power (infix_as x y) n) = (infix_as (power x n) (power y n))).
Proof.
intros x y comm.
apply natlike_ind.
rewrite 3!Power_0.
now rewrite Unit_def_r.
intros n Hn IHn.
unfold Zsucc.
rewrite 3!(Power_s _ _ Hn).
rewrite IHn.
rewrite <- Assoc.
rewrite (Assoc x).
rewrite <- (Power_comm1 _ _ comm _ Hn).
now rewrite <- 2!Assoc.
Qed.

End Exponentiation.