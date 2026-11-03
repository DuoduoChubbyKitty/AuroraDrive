def srgb(c):
    c=c/255
    return c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
def lum(h):
    h=h.lstrip('#'); r,g,b=int(h[0:2],16),int(h[2:4],16),int(h[4:6],16)
    return 0.2126*srgb(r)+0.7152*srgb(g)+0.0722*srgb(b)
def ratio(a,b):
    la,lb=lum(a),lum(b); hi,lo=max(la,lb),min(la,lb); return (hi+0.05)/(lo+0.05)
fails=[]
def ck(name,fg,bg,need=4.5,label=""):
    r=ratio(fg,bg); ok = r>=need
    if not ok: fails.append((name,fg,bg,round(r,2),need))
    print(f"{'OK ' if ok else 'FAIL'} {r:6.2f}  {name:48} {fg} / {bg}  (>{need})")

D={"bg-base":"#070A0F","bg-surface":"#0B1017","bg-card":"#101823","bg-elevated":"#16202D","bg-inset":"#0A0E14",
 "text-primary":"#E9EEF7","text-secondary":"#A9B4C4","text-tertiary":"#8A97A8","text-disabled":"#687484",
 "accent":"#35E0A1","accent-2":"#7C8CF8","accent-3":"#C56CF0","success":"#3DD68C","warning":"#F5A524",
 "danger":"#FF5A5F","info":"#4EA8FF","state-e2e":"#35E0A1","state-yolo":"#7C8CF8","state-rule":"#8A97A8",
 "stroke-input":"#5F748F","stroke-strong":"#3A4A60"}
L={"bg-base":"#F6F8FB","bg-surface":"#FFFFFF","bg-card":"#FFFFFF","bg-elevated":"#FFFFFF","bg-inset":"#EDF1F6",
 "text-primary":"#0B1119","text-secondary":"#445061","text-tertiary":"#5A6675","text-disabled":"#7A8593",
 "accent":"#0A7A55","accent-2":"#4F5FD6","accent-3":"#8E2FB0","success":"#0A7343","warning":"#8F5B04",
 "danger":"#C62A2F","info":"#1A5FBF","state-e2e":"#0A7A55","state-yolo":"#4F5FD6","state-rule":"#5A6675",
 "stroke-input":"#7F8C9B","stroke-strong":"#AEB8C6"}

for nm,P,bgs in (("DARK",D,["bg-base","bg-surface","bg-card","bg-elevated","bg-inset"]),
                 ("LIGHT",L,["bg-base","bg-surface","bg-card","bg-inset"])):
    print("="*104); print(nm); print("="*104)
    for b in bgs:
        for t in ["text-primary","text-secondary","text-tertiary"]:
            ck(f"{t} on {b}",P[t],P[b],4.5,"text")
    for b in bgs:
        ck(f"text-disabled on {b}",P["text-disabled"],P[b],3.0,"disabled")
    for b in bgs:
        for c in ["accent","accent-2","accent-3","success","warning","danger","info","state-e2e","state-yolo","state-rule"]:
            ck(f"{c} on {b}",P[c],P[b],4.5,"accent")
    for b in bgs:
        ck(f"stroke-input on {b}",P["stroke-input"],P[b],3.0,"input")
    print()

print("="*104); print("BUTTON / SPECIAL COMBOS"); print("="*104)
ck("DARK primary btn ink on accent","#04120C","#35E0A1",4.5,"btn")
ck("DARK primary btn hover ink on accent-hover","#04120C","#2ECB93",4.5,"btn")
ck("LIGHT primary btn white on accent","#FFFFFF","#0A7A55",4.5,"btn")
ck("LIGHT primary btn hover white","#FFFFFF","#08684A",4.5,"btn")
ck("LIGHT accent-fill badge ink","#04120C","#35E0A1",4.5,"btn")
ck("LIGHT accent-fill badge text on white","#0A7A55","#FFFFFF",4.5,"btn")
ck("DARK secondary btn text on elevated","#E9EEF7","#16202D",4.5,"btn")
ck("LIGHT secondary btn text on inset","#0B1119","#EDF1F6",4.5,"btn")
ck("DARK ghost btn text on base","#E9EEF7","#070A0F",4.5,"btn")
ck("LIGHT ghost btn text on base","#0B1119","#F6F8FB",4.5,"btn")
ck("DARK code text on inset","#E9EEF7","#0A0E14",4.5,"code")
ck("LIGHT code text on inset","#0B1119","#EDF1F6",4.5,"code")
ck("DARK focus ring on base","#35E0A1","#070A0F",3.0,"focus")
ck("LIGHT focus ring on base","#0A7A55","#F6F8FB",3.0,"focus")
ck("DARK focus ring on card","#35E0A1","#101823",3.0,"focus")
ck("LIGHT focus ring on card","#0A7A55","#FFFFFF",3.0,"focus")
ck("DARK danger text on card","#FF5A5F","#101823",4.5,"err")
ck("LIGHT danger text on card","#C62A2F","#FFFFFF",4.5,"err")
ck("DARK warning text on card","#F5A524","#101823",4.5,"warn")
ck("LIGHT warning text on card","#8F5B04","#FFFFFF",4.5,"warn")
ck("DARK success text on card","#3DD68C","#101823",4.5,"ok")
ck("LIGHT success text on card","#0A7343","#FFFFFF",4.5,"ok")
ck("DARK state-rule on card","#8A97A8","#101823",4.5,"state")
ck("LIGHT state-rule on card","#5A6675","#FFFFFF",4.5,"state")
print()
print("TOTAL FAILURES:",len(fails))
for f in fails: print("  ",f)

# ── 追加：语法高亮与描边复测（见 DESIGN_SYSTEM.md §2.4 末表） ──────────
SYN_D={"comment":"#76849A","keyword":"#A78BFA","string":"#35E0A1","number":"#F5A524",
       "function":"#4EA8FF","type":"#7C8CF8","punct":"#8A97A8","path":"#E9EEF7"}
SYN_L={"comment":"#5A6675","keyword":"#7A3FB0","string":"#0A7A55","number":"#8F5B04",
       "function":"#1A5FBF","type":"#4F5FD6","punct":"#5A6675","path":"#0B1119"}
print("\n=== SYNTAX HIGHLIGHT ===")
for k,v in SYN_D.items(): ck(f"syn-{k}",v,"#0A0E14",4.5)
for k,v in SYN_L.items(): ck(f"syn-{k}",v,"#EDF1F6",4.5)
print("\n=== TIER / ACCENT SPECIALS ===")
ck("tier-e2e",       "#35E0A1","#101823",4.5)
ck("tier-yolo",      "#7C8CF8","#101823",4.5)
ck("tier-rule",      "#8A97A8","#101823",4.5)
ck("tier-e2e light", "#0A7A55","#FFFFFF",4.5)
ck("tier-yolo light","#4F5FD6","#FFFFFF",4.5)
ck("tier-rule light","#5A6675","#FFFFFF",4.5)
ck("accent-hover dark",  "#2ECB93","#070A0F",4.5)
ck("accent-hover light", "#08684A","#F6F8FB",4.5)
ck("stroke-input dark on elevated", "#5F748F","#16202D",3.0)
print("\n=== TOTAL FAILURES:", len(fails), "===")
for x in fails: print("  ", x)
