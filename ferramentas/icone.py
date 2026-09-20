import math
from PIL import Image, ImageDraw

SS = 4                      # supersampling para bordas limpas
S  = 1024 * SS
CX, CY  = 512 * SS, 424 * SS
R_RING  = 300 * SS
W_RING  = 34 * SS
R_HUB   = 58 * SS
R_BLADE = 236 * SS
A0, A1  = 7.0, 24.0         # meia-abertura: estreita no cubo, larga na ponta
SWEEP   = 26.0              # arqueamento da pa, em graus

img = Image.new("RGB", (S, S))
d = ImageDraw.Draw(img)
TOPO, BAIXO = (0x62, 0xB4, 0xF0), (0x25, 0x62, 0x9E)
for y in range(S):
    t = y / (S - 1)
    d.line([(0, y), (S, y)],
           fill=tuple(int(TOPO[i] + (BAIXO[i] - TOPO[i]) * t) for i in range(3)))
BRANCO = (255, 255, 255)

def pt(ang, r):
    a = math.radians(ang)
    return (CX + r * math.sin(a), CY - r * math.cos(a))

N = 40
for base in (0, 90, 180, 270):
    esq, dire = [], []
    for i in range(N + 1):
        t  = i / N
        r  = R_HUB + t * (R_BLADE - R_HUB)
        c  = base + SWEEP * t                          # eixo gira: pa arqueada
        ha = A0 + (A1 - A0) * math.sin(t * math.pi / 2)
        esq.append(pt(c - ha, r))
        dire.append(pt(c + ha, r))
    # ponta arredondada: arco de verdade ligando as duas bordas
    c1 = base + SWEEP
    ponta = [pt(c1 - A1 + (2 * A1) * (k / 14), R_BLADE) for k in range(1, 14)]
    pts = esq + ponta + dire[::-1]
    d.polygon(pts, fill=BRANCO)
    d.line(pts + [pts[0]], fill=BRANCO, width=10 * SS, joint="curve")

fundo_cy = tuple(int(TOPO[i] + (BAIXO[i] - TOPO[i]) * (CY / (S - 1))) for i in range(3))
d.ellipse([CX - 50 * SS, CY - 50 * SS, CX + 50 * SS, CY + 50 * SS], fill=fundo_cy)
d.ellipse([CX - 34 * SS, CY - 34 * SS, CX + 34 * SS, CY + 34 * SS], fill=BRANCO)

d.ellipse([CX - R_RING, CY - R_RING, CX + R_RING, CY + R_RING],
          outline=BRANCO, width=W_RING)
d.rounded_rectangle([CX - 30 * SS, CY + R_RING - 22 * SS, CX + 30 * SS, 846 * SS],
                    radius=26 * SS, fill=BRANCO)
d.rounded_rectangle([CX - 150 * SS, 846 * SS, CX + 150 * SS, 898 * SS],
                    radius=26 * SS, fill=BRANCO)

img.resize((1024, 1024), Image.LANCZOS).save("icon-1024.png", "PNG")
print("ok")
