"""gen_grpo_slide.py -- single production slide: GRPO with GPU/CPU distinction.

Based on "2 many games" but:
  - Left side: policy (GPU) fans out to G trajectories
  - Each trajectory: GPU generates, CPU evaluates (environment)
  - Right side: rewards compared against group mean, above → reinforce, below → suppress
  - GPU/CPU explicitly labeled with colour-coded lane indicators on each trajectory

Canvas 1920x1080. Minimal text. Run: python3 gen_grpo_slide.py
"""

BG = "#F4FBF7"
CARD = "#FFFFFF"
BORDER = "#CDE9DC"
INK = "#14442F"
GREEN = "#1B7A55"
RED = "#C0392B"
GRAY = "#8FA69B"
AMBER = "#B8860B"
AMBER_BG = "#FBF3E0"

W, H = 1920, 1080


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


class Page:
    def __init__(self, name):
        self.name = name
        self.cells = []
        self.n = 1

    def _id(self):
        self.n += 1
        return f"c{self.n}"

    def raw(self, style, x, y, w, h, value=""):
        i = self._id()
        self.cells.append(
            f'<mxCell id="{i}" value="{esc(value)}" style="{style}" vertex="1" parent="1">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
        return i

    def rect(self, x, y, w, h, fill=CARD, stroke=BORDER, sw=4, r=14, value="",
             fontsize=28, fontcolor=INK, bold=0):
        style = (f"rounded=1;arcSize={r};fillColor={fill};strokeColor={stroke};"
                 f"strokeWidth={sw};fontSize={fontsize};"
                 f"fontColor={fontcolor};fontStyle={bold};verticalAlign=middle;"
                 f"align=center;shadow=0;html=1;whiteSpace=wrap;")
        return self.raw(style, x, y, w, h, value)

    def dot(self, cx, cy, r, fill=GREEN, stroke="none", sw=0, value="", fontsize=26,
            fontcolor="#FFFFFF", bold=1):
        style = (f"ellipse;fillColor={fill};strokeColor={stroke};strokeWidth={sw};"
                 f"fontSize={fontsize};fontColor={fontcolor};fontStyle={bold};"
                 f"verticalAlign=middle;align=center;html=1;")
        return self.raw(style, cx - r, cy - r, 2 * r, 2 * r, value)

    def text(self, x, y, w, h, value, fontsize=28, fontcolor=INK, bold=0,
             align="center"):
        style = (f"text;html=1;strokeColor=none;fillColor=none;align={align};"
                 f"verticalAlign=middle;fontSize={fontsize};fontColor={fontcolor};"
                 f"fontStyle={bold};whiteSpace=wrap;")
        return self.raw(style, x, y, w, h, value)

    def line(self, x1, y1, x2, y2, stroke=INK, sw=4, dashed=0, arrow="none"):
        i = self._id()
        style = (f"endArrow={arrow};strokeColor={stroke};strokeWidth={sw};"
                 f"dashed={dashed};html=1;rounded=0;"
                 f"endFill={'1' if arrow != 'none' else '0'};endSize=6;")
        self.cells.append(
            f'<mxCell id="{i}" style="{style}" edge="1" parent="1">'
            f'<mxGeometry relative="1" as="geometry">'
            f'<mxPoint x="{x1}" y="{y1}" as="sourcePoint"/>'
            f'<mxPoint x="{x2}" y="{y2}" as="targetPoint"/></mxGeometry></mxCell>')
        return i

    def curve(self, pts, stroke=INK, sw=6, arrow="block", dashed=0):
        i = self._id()
        style = (f"endArrow={arrow};strokeColor={stroke};strokeWidth={sw};dashed={dashed};"
                 f"html=1;rounded=1;curved=1;endFill=1;endSize=6;")
        wp = "".join(f'<mxPoint x="{x}" y="{y}"/>' for x, y in pts[1:-1])
        self.cells.append(
            f'<mxCell id="{i}" style="{style}" edge="1" parent="1">'
            f'<mxGeometry relative="1" as="geometry">'
            f'<mxPoint x="{pts[0][0]}" y="{pts[0][1]}" as="sourcePoint"/>'
            f'<mxPoint x="{pts[-1][0]}" y="{pts[-1][1]}" as="targetPoint"/>'
            f'<Array as="points">{wp}</Array></mxGeometry></mxCell>')
        return i

    def xml(self):
        body = "".join(self.cells)
        return (f'<diagram name="{esc(self.name)}">'
                f'<mxGraphModel dx="{W}" dy="{H}" grid="0" gridSize="10" guides="1" '
                f'tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" '
                f'pageWidth="{W}" pageHeight="{H}" math="0" shadow="0" '
                f'background="{BG}"><root><mxCell id="0"/>'
                f'<mxCell id="1" parent="0"/>{body}</root></mxGraphModel></diagram>')


def build():
    p = Page("GRPO")

    # ===== LEFT: policy (GPU) =====
    p.rect(70, 370, 240, 300, fill=CARD, stroke=GREEN, sw=8, r=22,
           value="policy", fontsize=36, bold=1, fontcolor=GREEN)
    # GPU chip label under policy
    p.rect(110, 690, 160, 58, fill=GREEN, stroke="none", sw=0, r=24,
           value="GPU", fontsize=32, fontcolor="#FFFFFF", bold=1)

    # ===== MIDDLE: G=5 trajectories, each showing generate(GPU) → evaluate(CPU) =====
    ys = [140, 310, 480, 700, 870]
    outcomes = ["win", "win", "win", "loss", "loss"]

    for y, outcome in zip(ys, outcomes):
        # fan-out arrow from policy
        p.curve([(310, 520), (380, 520), (410, y + 42), (460, y + 42)],
                stroke=GRAY, sw=4)

        # generate box (GPU work)
        p.rect(460, y, 250, 84, fill=CARD, stroke=GREEN, sw=5,
               value="generate", fontsize=30, bold=0, fontcolor=GREEN)

        # arrow from generate to evaluate
        p.curve([(710, y + 42), (750, y + 42)], stroke=GRAY, sw=5)

        # evaluate box (CPU work -- environment / tool / game)
        p.rect(760, y, 250, 84, fill=AMBER_BG, stroke=AMBER, sw=5,
               value="evaluate", fontsize=30, bold=0, fontcolor=AMBER)

        # arrow from evaluate to reward dot
        col = GREEN if outcome == "win" else RED
        p.curve([(1010, y + 42), (1060, y + 42)], stroke=col, sw=6)

        # reward dot
        p.dot(1120, y + 42, 44, fill=col, value=outcome, fontsize=28)

    # GPU/CPU legend between the two column headers
    p.text(460, 1010, 250, 50, "GPU", fontsize=32, fontcolor=GREEN, bold=1)
    p.text(760, 1010, 250, 50, "CPU", fontsize=32, fontcolor=AMBER, bold=1)

    # ===== RIGHT: group average + reinforce/suppress =====
    p.line(1240, 80, 1240, 960, stroke=INK, sw=7, dashed=1)
    p.text(1150, 30, 200, 50, "group avg", fontsize=30, bold=1)

    for y, outcome in zip(ys, outcomes):
        if outcome == "win":
            p.curve([(1280, y + 42), (1420, y + 42), (1450, y + 12)],
                    stroke=GREEN, sw=10)
        else:
            p.curve([(1280, y + 42), (1420, y + 42), (1450, y + 72)],
                    stroke=RED, sw=10)

    # reinforce / suppress labels
    p.text(1490, 200, 400, 60, "reinforce", fontsize=34, bold=1,
           fontcolor=GREEN, align="left")
    p.text(1490, 790, 400, 60, "suppress", fontsize=34, bold=1,
           fontcolor=RED, align="left")

    # ===== feedback loop arrow: bottom, drops to y=1060, text below at y=1070 =====
    p.curve([(1240, 960), (700, 1050), (190, 960), (190, 680)],
            stroke=INK, sw=8, dashed=1)
    p.text(480, 1060, 440, 50, "update policy weights",
           fontsize=30, fontcolor=INK, bold=0)

    return p


def main():
    page = build()
    xml = ('<mxfile host="app.diagrams.net" version="24.0.0" type="device">'
           + page.xml() + "</mxfile>")
    with open("grpo_slide.drawio", "w") as f:
        f.write(xml)
    print("wrote grpo_slide.drawio (1 page)")


if __name__ == "__main__":
    main()
