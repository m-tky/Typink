// template.typ - 理系ノート用テンプレート

#let vf(v) = $bold(v)$          // ベクトル場
#let grad = $nabla$              // 勾配
#let div = $nabla dot$           // 発散
#let curl = $nabla times$        // 回転
#let Rey = $"Re"$                // レイノルズ数
#let DDt(f) = $(D #f)/(D t)$    // 物質微分

#set page(width: 210mm, height: 297mm, margin: 20mm)
#set text(font: "IBM Sans Plex", size: 11pt)
