# throw-ball

## 概要

MR 空間でボールを投げられます

`ImmersiveView` に遷移すると、ボールが落ちてきてそのボールを握ると、ボールが飛んでいきます

壁や床にぶつかると跳ね返り、重力によって落下します

[1226*visionpro*ボール投げるアプリ\_デモ](https://youtu.be/CDOg7hgqkaI)

## 説明

### `ViewModel.swift`

`glabGesture`という関数の中で、ハンドトラッキングした親指とそれ以外の 4 本の指先の距離を検出して、一定の閾値を超えて近づいている場合にボールを投げる処理が行う

ボールが投げられる向きは `calculateForceDirection` 関数で決定される。`handAnchor`の`originFromAnchorTransform`から`rotation`を取得して、それを世界座標系に変換している

ボールを投げる強さは固定値として確定されている。`ballEntity.addForce(calculateForceDirection(handAnchor: handAnchor) * 4, relativeTo: nil)`の`4`がその値となる。この値を変えるとボールが飛んでいく速度が変わる
