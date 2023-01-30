{-# language PostfixOperators #-}

module Core where

import qualified IVarSet as IS
import Common
import Interval
import Substitution
import CoreTypes


-- Context manipulation
----------------------------------------------------------------------------------------------------

-- | Get a fresh ivar, when not working under a Sub.
freshI :: (NCofArg => IVar -> a) -> (NCofArg => a)
freshI act =
  let fresh = dom ?cof in
  let ?cof  = mapDom (+1) ?cof `ext` IVar fresh in
  act fresh
{-# inline freshI #-}

-- | Get a fresh ivar, when working under a Sub.
freshIS :: (SubArg => NCofArg => IVar -> a) -> (SubArg => NCofArg => a)
freshIS act =
  let fresh = dom ?cof in
  let ?sub  = mapDom (+1) ?sub `ext` IVar fresh in
  let ?cof  = mapDom (+1) ?cof `ext` IVar fresh in
  act fresh
{-# inline freshIS #-}

-- | Define the next fresh ivar to an expression.
defineI :: I -> (SubArg => a) -> (SubArg => a)
defineI i act = let ?sub = ?sub `ext` i in act
{-# inline defineI #-}

-- | Get a fresh fibrant var.
fresh :: (DomArg => Val -> a) -> (DomArg => a)
fresh act = let v = vVar ?dom in let ?dom = ?dom + 1 in act v
{-# inline fresh #-}

-- | Define the next fresh fibrant var to a value.
define :: Val -> (EnvArg => a) -> (EnvArg => a)
define ~v act = let ?env = EDef ?env v in act
{-# inline define #-}


-- Cof and Sys semantics
----------------------------------------------------------------------------------------------------

ctrue, cfalse :: F VCof
ctrue  = F VCTrue
cfalse = F VCFalse

cand :: F VCof -> F VCof -> F VCof
cand c1 ~c2 = case (unF c1, unF c2) of
  (VCFalse    , c2         ) -> cfalse
  (_          , VCFalse    ) -> cfalse
  (VCTrue     , c2         ) -> F c2
  (c1         , VCTrue     ) -> F c1
  (VCNe n1 is1, VCNe n2 is2) -> F (VCNe (NCAnd n1 n2) (is1 <> is2))
{-# inline cand #-}

iToVarSet :: I -> IS.IVarSet
iToVarSet = \case
  IVar x -> IS.singleton x
  _      -> mempty

vCofToVarSet :: F VCof -> IS.IVarSet
vCofToVarSet cof = case unF cof of
  VCTrue    -> mempty
  VCFalse   -> mempty
  VCNe _ is -> is

ceq :: F I -> F I -> F VCof
ceq c1 c2 = case (unF c1, unF c2) of
  (i, j) | i == j -> ctrue
  (i, j) -> matchIVar i
    (\x -> matchIVar j
     (\y -> F (VCNe (NCEq i j) (IS.singleton x <> IS.singleton y)))
     cfalse)
    cfalse

evalI :: SubArg => NCofArg => I -> F I
evalI i = F (doSub ?cof (sub i))

evalCofEq :: SubArg => NCofArg => CofEq -> F VCof
evalCofEq (CofEq i j) = ceq (evalI i) (evalI j)

evalCof :: SubArg => NCofArg => Cof -> F VCof
evalCof = \case
  CTrue       -> ctrue
  CAnd eq cof -> cand (evalCofEq eq) (evalCof cof)

conjIVarI :: NCof -> IVar -> I -> NCof
conjIVarI cof x i = mapSub id go cof where
  go _ j = matchIVar j (\y -> if x == y then i else j) j

conjNeCof :: NCof -> NeCof -> NCof
conjNeCof ncof necof = case necof of
  NCAnd c1 c2 -> ncof `conjNeCof` c1 `conjNeCof` c2
  NCEq i j    -> case (i, j) of
    (IVar x, IVar y) -> let (!x, !i) = if x > y then (x, IVar y)
                                                else (y, IVar x) in
                        conjIVarI ncof x i
    (IVar x, j     ) -> conjIVarI ncof x j
    (i     , IVar y) -> conjIVarI ncof y i
    _                -> impossible

conjVCof :: NCof -> F VCof -> NCof
conjVCof ncof cof = case unF cof of
  VCFalse      -> impossible
  VCTrue       -> ncof
  VCNe necof _ -> conjNeCof ncof necof
{-# noinline conjVCof #-}

bindCof :: NeCof -> (NCofArg => a) -> NCofArg => BindCof a
bindCof cof act = let ?cof = conjNeCof ?cof cof in BindCof cof act
{-# inline bindCof #-}

bindCoff :: NeCof -> (NCofArg => F a) -> NCofArg => F (BindCof a)
bindCoff cof act = let ?cof = conjNeCof ?cof cof in F (BindCof cof (unF act))
{-# inline bindCoff #-}

bindCofLazy :: NeCof -> (NCofArg => a) -> NCofArg => BindCofLazy a
bindCofLazy cof act = let ?cof = conjNeCof ?cof cof in BindCofLazy cof act
{-# inline bindCofLazy #-}

bindI :: Name -> (NCofArg => F I -> a) -> NCofArg => BindI a
bindI x act = freshI \i -> BindI x i (act (F (IVar i)))
{-# inline bindI #-}

bindIf :: Name -> (NCofArg => F I -> F a) -> NCofArg => F (BindI a)
bindIf x act = freshI \i -> F (BindI x i (unF (act (F (IVar i)))))
{-# inline bindIf #-}

bindILazy :: Name -> (NCofArg => F I -> F a) -> NCofArg => F (BindILazy a)
bindILazy x act = freshI \i -> F (BindILazy x i (unF (act (F (IVar i)))))
{-# inline bindILazy #-}

bindILazynf :: Name -> (NCofArg => F I -> F a) -> NCofArg => BindILazy a
bindILazynf x act = unF (bindILazy x act)
{-# inline bindILazynf #-}

bindIS :: Name -> (SubArg => NCofArg => F I -> F a) -> SubArg => NCofArg => F (BindI a)
bindIS x act = freshIS \i -> F (BindI x i (unF (act (F (IVar i)))))
{-# inline bindIS #-}

bindILazyS :: Name -> (SubArg => NCofArg => F I -> F a) -> SubArg => NCofArg => F (BindILazy a)
bindILazyS x act = freshIS \i -> F (BindILazy x i (unF (act (F (IVar i)))))
{-# inline bindILazyS #-}

bindILazySnf :: Name -> (SubArg => NCofArg => F I -> F a) -> SubArg => NCofArg => BindILazy a
bindILazySnf x act = unF (bindILazyS x act)
{-# inline bindILazySnf #-}

vsempty :: F VSys
vsempty = F (VSNe NSEmpty mempty)
{-# inline vsempty #-}

vscons :: NCofArg => F VCof -> (NCofArg => Val) -> F VSys -> F VSys
vscons cof v ~sys = case unF cof of
  VCTrue      -> F (VSTotal v)
  VCFalse     -> sys
  VCNe cof is -> case unF sys of
    VSTotal v'   -> F (VSTotal v')
    VSNe sys is' -> F (VSNe (NSCons (bindCofLazy cof v) sys) (is <> is'))
{-# inline vscons #-}

evalSys :: SubArg => NCofArg => DomArg => EnvArg => Sys -> F VSys
evalSys = \case
  SEmpty          -> vsempty
  SCons cof t sys -> vscons (evalCof cof) (unF (evalf t)) (evalSys sys)

vshempty :: F VSysHCom
vshempty = F (VSHNe NSHEmpty mempty)
{-# inline vshempty #-}

vshcons :: NCofArg => F VCof -> Name -> (NCofArg => F I -> F Val) -> F VSysHCom -> F VSysHCom
vshcons cof i v ~sys = case unF cof of
  VCTrue      -> F (VSHTotal (unF (bindILazy i v)))
  VCFalse     -> sys
  VCNe cof is -> case unF sys of
    VSHTotal v'   -> F (VSHTotal v')
    VSHNe sys is' -> F (VSHNe (NSHCons (bindCof cof (bindILazynf i v)) sys) (is <> is'))
{-# inline vshcons #-}

vshconsS :: SubArg => NCofArg => F VCof -> Name -> (SubArg => NCofArg => F I -> F Val)
         -> F VSysHCom -> F VSysHCom
vshconsS cof i v ~sys = case unF cof of
  VCTrue      -> F (VSHTotal (bindILazySnf i v))
  VCFalse     -> sys
  VCNe cof is -> case unF sys of
    VSHTotal v'   -> F (VSHTotal v')
    VSHNe sys is' -> F (VSHNe (NSHCons (bindCof cof (bindILazySnf i v)) sys) (is <> is'))
{-# inline vshconsS #-}

evalSysHCom :: SubArg => NCofArg => DomArg => EnvArg => Name -> Sys -> F VSysHCom
evalSysHCom x = \case
  SEmpty          -> vshempty
  SCons cof t sys -> vshconsS (evalCof cof) x (\_ -> evalf t) (evalSysHCom x sys)


-- Mapping
----------------------------------------------------------------------------------------------------

mapBindCof :: NCofArg => BindCof a -> (NCofArg => a -> a) -> BindCof a
mapBindCof t f = bindCof (t^.binds) (f (t^.body))
{-# inline mapBindCof #-}

mapBindILazy :: NCofArg => BindILazy Val -> (NCofArg => F I -> Val -> F Val) -> F (BindILazy Val)
mapBindILazy t f = bindILazy (t^.name) \i -> f i (t ∙ unF i)
{-# inline mapBindILazy #-}

mapBindILazynf t f = unF (mapBindILazy t f); {-# inline mapBindILazynf #-}

mapNeSysHCom :: NCofArg => (NCofArg => F I -> Val -> F Val) -> F NeSysHCom -> F NeSysHCom
mapNeSysHCom f sys = F (go (unF sys)) where
  go :: NeSysHCom -> NeSysHCom
  go = \case
    NSHEmpty      -> NSHEmpty
    NSHCons t sys -> NSHCons (mapBindCof t \t -> mapBindILazynf t f) (go sys)
{-# inline mapNeSysHCom #-}

mapNeSysHComnf f sys = unF (mapNeSysHCom f sys); {-# inline mapNeSysHComnf #-}

mapNeSysHCom' :: NCofArg => (NCofArg => F I -> Val -> F Val)
              -> F (NeSysHCom, IS.IVarSet)
              -> F (NeSysHCom, IS.IVarSet)
mapNeSysHCom' f (F (sys, is)) = F (mapNeSysHComnf f (F sys), is)
{-# inline mapNeSysHCom' #-}

mapVSysHCom :: NCofArg => (NCofArg => F I -> Val -> F Val) -> F VSysHCom -> F VSysHCom
mapVSysHCom f sys = case unF sys of
  VSHTotal v   -> F (VSHTotal (mapBindILazynf v f))
  VSHNe sys is -> F (VSHNe (mapNeSysHComnf f (F sys)) is)
{-# inline mapVSysHCom #-}


----------------------------------------------------------------------------------------------------

localVar :: EnvArg => Ix -> Val
localVar x = go ?env x where
  go (EDef _ v) 0 = v
  go (EDef e _) x = go e (x - 1)
  go _          _ = impossible

-- | Apply a closure. Note: *lazy* in argument.
capp :: NCofArg => DomArg => NamedClosure -> Val -> Val
capp (NCl _ t) ~u = case t of
  CEval s env t -> let ?env = EDef env u; ?sub = s in eval t

  CCoePi (frc -> r) (frc -> r') (frc -> a) b (frc -> t) ->
    let x = frc u in
    coenf r r' (bindIf "j" \j -> b ∙ unF j ∘ coenf r' j a x) (t ∘ coenf r' r a x)

  CHComPi (frc -> r) (frc -> r') a b sys base ->
    hcom r r'
      (b ∘ u)
      (mapVSysHCom (\i t -> frc t ∘ u) (frc sys))
      (frc base ∘ u)


-- | Apply an ivar closure.
icapp :: NCofArg => DomArg => NamedIClosure -> I -> Val
icapp (NICl _ t) arg = case t of
  ICEval s env t -> let ?env = env; ?sub = ext s arg in eval t

  ICCoePathP (frc -> r) (frc -> r') a lhs rhs p ->
    let j = frc arg in
    com r r' (bindIf "i" \i -> a ∙ unF i ∘ unF j)
             (vshcons (ceq j (F I0)) "i" (\i -> lhs ∘ unF i) $
              vshcons (ceq j (F I1)) "i" (\i -> rhs ∘ unF i) $
              vshempty)
             (pappf (frc p) (lhs ∙ unF r') (rhs ∙ unF r') j)

  ICHComPathP (frc -> r) (frc -> r') a lhs rhs sys p ->
    let farg = frc arg in
    hcom r r' (a ∘ unF farg)
      (vshcons (ceq farg (F I0)) "i" (\i -> frc lhs) $
       vshcons (ceq farg (F I1)) "i" (\i -> frc rhs) $
       mapVSysHCom (\_ t -> pappf (frc t) lhs rhs farg) (frc sys))
      (pappf (frc p) lhs rhs farg)

-- isEquiv : (A → B) → U
-- isEquiv A B f :=
--     (g^1    : B → A)
--   × (linv^2 : (x^4 : A) → Path A x (g (f x)))
--   × (rinv^3 : (x^5 : B) → Path B (f (g x)) x)
--   × (coh    : (x^6 : A) →
--             PathP (i^7) (Path B (f (linv x {x}{g (f x)} i)) (f x))
--                   (refl B (f x))
--                   (rinv (f x)))

--   ICIsEquiv7 b (force -> f) (force -> g)(force -> linv) x ->
--     let ~i   = forceI arg
--         ~fx  = f `app` x
--         ~gfx = g `app` fx  in
--     path b (f `app` papp (linv `appf` x) x gfx i) fx

proj1 :: F Val -> Val
proj1 t = case unF t of
  VPair t _ -> t
  VNe t is  -> VNe (NProj1 t) is
  _         -> impossible
{-# inline proj1 #-}

proj1f  t = frc  (proj1 t); {-# inline proj1f  #-}
proj1fS t = frcS (proj1 t); {-# inline proj1fS #-}

proj2 :: F Val -> Val
proj2 t = case unF t of
  VPair _ u -> u
  VNe t is  -> VNe (NProj2 t) is
  _         -> impossible
{-# inline proj2 #-}

proj2f  t = frc  (proj2 t); {-# inline proj2f #-}
proj2fS t = frcS (proj2 t); {-# inline proj2fS #-}

natElim :: NCofArg => DomArg => Val -> Val -> F Val -> F Val -> Val
natElim p z s n = case unF n of
  VZero             -> z
  VSuc (frc -> n)   -> s ∘ unF n ∙ natElim p z s n
  VNe n is          -> VNe (NNatElim p z (unF s) n) is
  _                 -> impossible

natElimf  p z s n = frc  (natElim p z s n); {-# inline natElimf  #-}
natElimfS p z s n = frcS (natElim p z s n); {-# inline natElimfS #-}

-- | Apply a path.
papp :: NCofArg => DomArg => F Val -> Val -> Val -> F I -> Val
papp ~t ~u0 ~u1 i = case unF i of
  I0     -> u0
  I1     -> u1
  IVar x -> case unF t of
    VPLam _ _ t -> t ∙ IVar x
    VNe t is    -> VNe (NPApp t u0 u1 (IVar x)) (IS.insert x is)
    _           -> impossible
{-# inline papp #-}

pappf  ~t ~u0 ~u1 i = frc  (papp t u0 u1 i); {-# inline pappf  #-}
pappfS ~t ~u0 ~u1 i = frcS (papp t u0 u1 i); {-# inline pappfS #-}

--------------------------------------------------------------------------------

infixl 8 ∙
class Apply a b c a1 a2 | a -> b c a1 a2 where
  (∙) :: a1 => a2 => a -> b -> c

instance Apply NamedClosure Val Val NCofArg DomArg where
  (∙) = capp; {-# inline (∙) #-}

instance Apply (F Val) Val Val NCofArg DomArg where
  (∙) t u = case unF t of
    VLam t   -> capp t u
    VNe t is -> VNe (NApp t u) is
    _        -> impossible
  {-# inline (∙) #-}

instance Apply (BindI a) I a (SubAction a) NCofArg where
  (∙) (BindI x i a) j =
    let s = setCod i (idSub (dom ?cof)) `ext` j
    in doSub s a
  {-# inline (∙) #-}

instance Apply (BindILazy a) I a (SubAction a) NCofArg where
  (∙) (BindILazy x i a) j =
    let s = setCod i (idSub (dom ?cof)) `ext` j
    in doSub s a
  {-# inline (∙) #-}

instance Apply NamedIClosure I Val NCofArg DomArg where
  (∙) = icapp; {-# inline (∙) #-}

infixl 8 ∘
class ApplyF a b c a1 a2 a3 | a -> b c a1 a2 a3 where
  (∘) :: a1 => a2 => a3 => a -> b -> F c

instance ApplyF NamedClosure Val Val NCofArg DomArg () where
  (∘) x ~y = frc (x ∙ y); {-# inline (∘) #-}

instance ApplyF (F Val) Val Val NCofArg DomArg () where
  (∘) x y = frc (x ∙ y); {-# inline (∘) #-}

instance Force a fa => ApplyF (BindI a) I fa (SubAction a) NCofArg DomArg where
  (∘) x y = frc (x ∙ y); {-# inline (∘) #-}

instance Force a fa => ApplyF (BindILazy a) I fa (SubAction a) NCofArg DomArg where
  (∘) x y = frc (x ∙ y); {-# inline (∘) #-}

instance ApplyF NamedIClosure I Val NCofArg DomArg () where
  (∘) x y = frc (x ∙ y); {-# inline (∘) #-}

--------------------------------------------------------------------------------

-- assumption: r /= r'
coed :: NCofArg => DomArg => F I -> F I -> F (BindI Val) -> F Val -> F Val
coed r r' topA t = case unF topA ^. body of

  VPi (rebind topA -> a) (rebind topA -> b) ->
    F (VLam (NCl (b^.body.name) (CCoePi (unF r) (unF r') a b (unF t))))

  VSg (rebindf topA -> a) (rebindf topA -> b) ->
    let t1 = proj1f t
        t2 = proj2f t
    in F (VPair (coednf r r' a t1)
                (coednf r r' (bindIf "j" \j -> coe r j a t1) t2))

  VNat ->
    t

  VPathP (rebind topA -> a) (rebind topA -> lhs) (rebind topA -> rhs) ->
    F (VPLam (lhs ∙ unF r') (rhs ∙ unF r')
             (NICl (a^.body.name) (ICCoePathP (unF r) (unF r') a lhs rhs (unF t))))

  VU ->
    t

  -- Note: I don't need to rebind the "is"! It can be immediately weakened
  -- to the outer context.
  VNe (rebind topA -> n) is ->
    F (VNe (NCoe (unF r) (unF r') (unF topA) (unF t))
           (IS.insertI (unF r) $ IS.insertI (unF r') is))

  VGlueTy a sys is ->
    uf

  _ ->
    impossible

coednf r r' a t = unF (coed r r' a t); {-# inline coednf #-}

coe :: NCofArg => DomArg => F I -> F I -> F (BindI Val) -> F Val -> F Val
coe r r' ~a t
  | unF r == unF r' = t
  | True            = coed r r' a t
{-# inline coe #-}

coenf r r' a t = unF (coe r r' a t); {-# inline coenf #-}

-- | Assumption: r /= r'
comdn :: NCofArg => DomArg => F I -> F I -> F (BindI Val) -> F (NeSysHCom, IS.IVarSet) -> F Val -> F Val
comdn r r' ~a sys ~b =
  hcomdn r r'
    (unF a ∘ unF r')
    (mapNeSysHCom' (\i t -> coe i r' a (frc t)) sys)
    (coed r r' a b)
{-# noinline comdn #-}

comdnnf r r' ~a sys ~b = unF (comdn r r' a sys b); {-# inline comdnnf #-}

com :: NCofArg => DomArg => F I -> F I -> F (BindI Val) -> F VSysHCom -> F Val -> Val
com r r' ~a ~sys ~b
  | unF r == unF r'            = unF b
  | VSHTotal v      <- unF sys = v ∙ unF r'
  | VSHNe nsys is   <- unF sys = comdnnf r r' a (F (nsys, is)) b
{-# inline com #-}

storeSysHCom :: F (NeSysHCom, IS.IVarSet) -> NeSysHComSub
storeSysHCom (F (sys, _)) = NSHSNe sys; {-# inline storeSysHCom #-}

-- | HCom with off-diagonal I args ("d") and neutral system arg ("n").
hcomdn :: NCofArg => DomArg => F I -> F I -> F Val -> F (NeSysHCom, IS.IVarSet) -> F Val -> F Val
hcomdn r r' a ts base = case unF a of

  VPi a b ->
    F $ VLam $ NCl (b^.name) $ CHComPi (unF r) (unF r') a b (storeSysHCom ts) (unF base)

  VSg a b ->
    F $ VPair
      (hcomdnnf r r' (frc a)
                     (mapNeSysHCom' (\_ t -> proj1f (frc t)) ts)
                     (proj1f base))
      (comdnnf r r' (bindIf "i" \i -> hcomn r i (frc a) (mapNeSysHCom' (\_ t -> proj1f (frc t)) ts)
                                                        (proj1f base))
                    (mapNeSysHCom' (\_ t -> proj2f (frc t)) ts)
                    (proj2f base))

  VNat -> uf

  VPathP a lhs rhs ->
    F $ VPLam lhs rhs
      $ NICl (a^.name)
      $ ICHComPathP (unF r) (unF r') a lhs rhs (storeSysHCom ts) (unF base)

  a@(VNe n is) ->
    F $ VNe (NHCom (unF r) (unF r') a (storeSysHCom ts) (unF base)) (is <> snd (unF ts))

  VU ->
    uf

  VGlueTy a sys is' ->
    uf

  _ ->
    impossible

-- | HCom with nothing known about semantic arguments.
hcom :: NCofArg => DomArg => F I -> F I -> F Val -> F VSysHCom -> F Val -> Val
hcom r r' ~a ~t ~b
  | unF r == unF r'          = unF b
  | VSHTotal v      <- unF t = v ∙ unF r'
  | VSHNe nsys is   <- unF t = hcomdnnf r r' a (F (nsys, is)) b
{-# inline hcom #-}

-- | HCom with neutral system input.
hcomn :: NCofArg => DomArg => F I -> F I -> F Val -> F (NeSysHCom, IS.IVarSet) -> F Val -> F Val
hcomn r r' ~a ~sys ~b
  | unF r == unF r' = b
  | True            = hcomdn r r' a sys b
{-# inline hcomn #-}

hcomdnnf r r' a sys base = unF (hcomdn r r' a sys base); {-# inline hcomdnnf #-}
hcomf r r' ~a ~t ~b = frc (hcom r r' a t b); {-# inline hcomf  #-}
hcomfS r r' ~a ~t ~b = frcS (hcom r r' a t b); {-# inline hcomfS  #-}

glueTy :: NCofArg => DomArg => Val -> F VSys -> Val
glueTy a sys = case unF sys of
  VSTotal b   -> proj1 (frc b)
  VSNe sys is -> VGlueTy a (NSSNe sys) is
{-# inline glueTy #-}

glueTyf a sys = frc (glueTy a sys); {-# inline glueTyf #-}
glueTyfS a sys = frcS (glueTy a sys); {-# inline glueTyfS #-}

glue :: Val -> F VSys -> Val
glue t sys = case unF sys of
  VSTotal v   -> v
  VSNe sys is -> VNe (NGlue t (NSSNe sys)) is
{-# inline glue #-}

gluef t sys = frc (glue t sys); {-# inline gluef #-}
gluefS t sys = frcS (glue t sys); {-# inline gluefS #-}

unglue :: NCofArg => DomArg => Val -> F VSys -> Val
unglue t sys = case unF sys of
  VSTotal teqv -> proj1f (proj2f (frc teqv)) ∙ t
  VSNe sys is  -> VNe (NUnglue t (NSSNe sys)) is
{-# inline unglue #-}

ungluef t sys = frc (unglue t sys); {-# inline ungluef #-}
ungluefS t sys = frcS (unglue t sys); {-# inline ungluefS #-}

eval :: SubArg => NCofArg => DomArg => EnvArg => Tm -> Val
eval = \case
  TopVar _ v        -> coerce v
  LocalVar x        -> localVar x
  Let x _ t u       -> define (eval t) (eval u)
  Pi x a b          -> VPi (eval a) (NCl x (CEval ?sub ?env b))
  App t u           -> evalf t ∙ eval u
  Lam x t           -> VLam (NCl x (CEval ?sub ?env t))
  Sg x a b          -> VSg (eval a) (NCl x (CEval ?sub ?env b))
  Pair t u          -> VPair (eval t) (eval u)
  Proj1 t           -> proj1 (evalf t)
  Proj2 t           -> proj2 (evalf t)
  U                 -> VU
  PathP x a t u     -> VPathP (NICl x (ICEval ?sub ?env a)) (eval t) (eval u)
  PApp t u0 u1 i    -> papp (evalf t) (eval u0) (eval u1) (evalI i)
  PLam l r x t      -> VPLam (eval l) (eval r) (NICl x (ICEval ?sub ?env t))
  Coe r r' x a t    -> coenf (evalI r) (evalI r') (bindIS x \_ -> evalf a) (evalf t)
  HCom r r' x a t b -> hcom (evalI r) (evalI r') (evalf a) (evalSysHCom x t) (evalf b)
  GlueTy a sys      -> glueTy (eval a) (evalSys sys)
  Glue t sys        -> glue (eval t) (evalSys sys)
  Unglue t sys      -> unglue (eval t) (evalSys sys)
  Nat               -> VNat
  Zero              -> VZero
  Suc t             -> VSuc (eval t)
  NatElim p z s n   -> natElim (eval p) (eval z) (evalf s) (evalf n)

evalf :: SubArg => NCofArg => DomArg => EnvArg => Tm -> F Val
evalf t = frc (eval t)
{-# inline evalf #-}

-- Forcing
----------------------------------------------------------------------------------------------------

class Force a b | a -> b where
  frc  :: NCofArg => DomArg => a -> F b
  frcS :: SubArg => NCofArg => DomArg => a -> F b

instance Force NeCof VCof where
  frc = \case
    NCEq i j    -> ceq (frc i) (frc j)
    NCAnd c1 c2 -> cand (frc c1) (frc c2)

  frcS = \case
    NCEq i j    -> ceq (frcS i) (frcS j)
    NCAnd c1 c2 -> cand (frcS c1) (frcS c2)

instance Force Val Val where
  frc = \case
    VSub v s                          -> let ?sub = s in frcS v
    VNe t is         | isUnblocked is -> frc t
    VGlueTy a sys is | isUnblocked is -> glueTyf a (frc sys)
    v                                 -> F v

  frcS = \case
    VSub v s                           -> let ?sub = sub s in frcS v
    VNe t is         | isUnblockedS is -> frcS t
                     | True            -> F (VNe (sub t) (sub is))
    VGlueTy a sys is | isUnblockedS is -> glueTyfS (sub a) (frcS sys)
                     | True            -> F (VGlueTy (sub a) (sub sys) (sub is))

    VPi a b      -> F (VPi (sub a) (sub b))
    VLam t       -> F (VLam (sub t))
    VPathP a t u -> F (VPathP (sub a) (sub t) (sub u))
    VPLam l r t  -> F (VPLam (sub l) (sub r) (sub t))
    VSg a b      -> F (VSg (sub a) (sub b))
    VPair t u    -> F (VPair (sub t) (sub u))
    VU           -> F VU
    VNat         -> F VNat
    VZero        -> F VZero
    VSuc t       -> F (VSuc (sub t))

instance Force Ne Val where
  frc = \case
    t@NLocalVar{}     -> F (VNe t mempty)
    NSub n s          -> let ?sub = s in frcS n
    NApp t u          -> frc t ∘ u
    NPApp t l r i     -> pappf (frc t) l r (frc i)
    NProj1 t          -> proj1f (frc t)
    NProj2 t          -> proj2f (frc t)
    NCoe r r' a t     -> coe (frc r) (frc r') (frc a) (frc t)
    NHCom r r' a ts t -> hcomf (frc r) (frc r') (frc a) (frc ts) (frc t)
    NUnglue t sys     -> ungluef t (frc sys)
    NGlue t sys       -> gluef t (frc sys)
    NNatElim p z s n  -> natElimf p z (frc s) (frc n)

  frcS = \case
    t@NLocalVar{}     -> F (VNe t mempty)
    NSub n s          -> let ?sub = sub s in frcS n
    NApp t u          -> frcS (frcS t ∙ u)
    NPApp t l r i     -> pappfS (frcS t) l r (frcS i)
    NProj1 t          -> proj1fS (frcS t)
    NProj2 t          -> proj2fS (frcS t)
    NCoe r r' a t     -> coe (frcS r) (frcS r') (frcS a) (frcS t)
    NHCom r r' a ts t -> hcomfS (frcS r) (frcS r') (frcS a) (frcS ts) (frcS t)
    NUnglue t sys     -> ungluefS t (frcS sys)
    NGlue t sys       -> gluefS t (frcS sys)
    NNatElim p z s n  -> natElimfS p z (frcS s) (frcS n)

instance Force NeSys VSys where
  frc = \case
    NSEmpty      -> vsempty
    NSCons t sys -> vscons (frc (t^.binds)) (t^.body) (frc sys)

  frcS = frc; {-# inline frcS #-}

instance Force NeSysSub VSys where
  frc = \case
    NSSNe sys    -> frc sys
    NSSSub sys s -> let ?sub = s in frcS sys
  {-# inline frc #-}

  frcS = \case
    NSSNe sys    -> frcS sys
    NSSSub sys s -> let ?sub = sub s in frcS sys
  {-# inline frcS #-}

instance Force I I where
  frc  i = F (doSub ?cof i); {-# inline frc #-}
  frcS i = F (doSub ?cof (doSub ?sub i)); {-# inline frcS #-}

instance Force a fa => Force (BindI a) (BindI fa) where

  -- TODO: review
  frc (BindI x i a) =
    let ?cof = setDom (i + 1) (setCod i ?cof) `ext` IVar i in
    F (BindI x i (unF (frc a)))
  {-# inline frc #-}

  -- TODO: review
  frcS (BindI x i a) =
    let fresh = dom ?cof in
    let ?sub  = mapDom (+1) (setCod i ?sub) `ext` IVar fresh in
    let ?cof  = mapDom (+1) ?cof `ext` IVar fresh in
    F (BindI x fresh (unF (frcS a)))
  {-# inline frcS #-}

instance Force NeSysHCom VSysHCom where
  frc = \case
    NSHEmpty ->
      vshempty
    NSHCons t sys ->
      vshcons (frc (t^.binds)) (t^.body.name) (\i -> t^.body ∘ unF i) (frc sys)

  frcS = \case
    NSHEmpty ->
      vshempty
    NSHCons t sys ->
      vshconsS (frcS (t^.binds)) (t^.body.name) (\i -> frcS (t^.body ∙ unF i)) (frcS sys)

instance Force NeSysHComSub VSysHCom where
  frc = \case
    NSHSNe sys    -> frc sys
    NSHSSub sys s -> let ?sub = s in frcS sys
  {-# inline frc #-}

  frcS = \case
    NSHSNe sys    -> frcS sys
    NSHSSub sys s -> let ?sub = sub s in frcS sys
  {-# inline frcS #-}


-- Quotation
----------------------------------------------------------------------------------------------------

class Quote a b | a -> b where
  quote  :: NCofArg => DomArg => a -> b
  quoteS :: SubArg => NCofArg => DomArg => a -> b

instance Quote I I where
  quote  = unF . frc
  quoteS = unF . frcS

instance Quote Ne Tm where
  quote = uf
  quoteS = uf


-- quoteNe :: IDomArg => NCofArg => DomArg => Ne -> Tm
-- quoteNe n = case unSubNe n of
--   NLocalVar x          -> LocalVar (lvlToIx ?dom x)
--   NSub{}               -> impossible
--   NApp t u             -> App (quoteNe t) (quote u)
--   NPApp n l r i        -> PApp (quoteNe n) (quote l) (quote r) (quoteI i)
--   NProj1 t             -> Proj1 (quoteNe t)
--   NProj2 t             -> Proj2 (quoteNe t)
--   -- NCoe r r' x a t      -> Coe (quoteI r) (quoteI r') x (bindI \_ -> quote a) (quote t)
--   -- NHCom r r' x a sys t -> HCom (quoteI r) (quoteI r') x (quote a) (quoteSys sys) (quote t)
--   NUnglue a sys        -> Unglue (quote a) (quoteSys sys)
--   NGlue a sys          -> Glue (quote a) (quoteSys sys)
--   NNatElim p z s n     -> NatElim (quote p) (quote z) (quote s) (quoteNe n)

-- quoteNeCof :: IDomArg => NCofArg => NeCof -> Cof -> Cof
-- quoteNeCof ncof acc = case ncof of
--   NCEq i j    -> CAnd (CofEq i j) acc
--   NCAnd c1 c2 -> quoteNeCof c1 (quoteNeCof c2 acc)

-- quoteCof :: IDomArg => NCofArg => F VCof -> Cof
-- quoteCof cof = case unF cof of
--   VCTrue      -> CTrue
--   VCFalse     -> impossible
--   VCNe ncof _ -> quoteNeCof ncof CTrue

-- quoteSys :: IDomArg => NCofArg => DomArg => NSys VCof -> Sys
-- quoteSys = \case
--   NSEmpty ->
--     SEmpty
--   NSCons (forceCof -> cof) t sys ->
--     SCons (quoteCof cof) (bindCof cof (bindI \_ -> quote t)) (quoteSys sys)

-- quoteCl :: IDomArg => NCofArg => DomArg => Closure -> Tm
-- quoteCl t = bind \v -> quote (capp t v)
-- {-# inline quoteCl #-}

-- quoteICl :: IDomArg => NCofArg => DomArg => IClosure -> Tm
-- quoteICl t = bindI \(IVar -> i) -> quote (icapp t i)
-- {-# inline quoteICl #-}

-- -- TODO: optimized quote' would take an extra subarg
-- quote :: IDomArg => NCofArg => DomArg => Val -> Tm
-- quote v = case unF (force v) of
--   VSub{}         -> impossible
--   VNe n _        -> quoteNe n
--   VGlueTy a sys  -> GlueTy (quote a) (quoteSys (_nsys sys))
--   VPi x a b      -> Pi x (quote a) (quoteCl b)
--   VLam x t       -> Lam x (quoteCl t)
--   VPathP x a t u -> PathP x (quoteICl a) (quote t) (quote u)
--   VPLam l r x t  -> PLam (quote l) (quote r) x (quoteICl t)
--   VSg x a b      -> Sg x (quote a) (quoteCl b)
--   VPair t u      -> Pair (quote t) (quote u)
--   VU             -> U
--   VNat           -> Nat
--   VZero          -> Zero
--   VSuc n         -> Suc (quote n)
-- -}
