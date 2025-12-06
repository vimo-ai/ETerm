//
//  PathGradientShader.metal
//  ETerm
//
//  沿路径均匀分布的渐变着色器
//

#include <metal_stdlib>
using namespace metal;

// 顶点数据结构
struct PolylineVertex {
    float2 position;
    float4 color;
};

// 线段查询结果
struct LineSegQuery {
    float distance;
    float2 closestPoint;
    float tVal;
};

// 计算点到线段的最近距离和参数 t
LineSegQuery distanceToLineSeg(float2 P, float2 A, float2 B) {
    float2 AB = B - A;
    float2 AP = P - A;
    float lenSqAB = length_squared(AB);

    // 避免除以零
    if (lenSqAB < 0.0001) {
        return LineSegQuery{distance(P, A), A, 0.0};
    }

    float t = dot(AP, AB) / lenSqAB;
    t = clamp(t, 0.0f, 1.0f);
    float2 cp = A + t * AB;
    return LineSegQuery{distance(cp, P), cp, t};
}

// 预乘 alpha
float4 convertToPreMultipliedAlpha(float4 colorIn) {
    float alpha = colorIn.a;
    float4 colorOut = colorIn * alpha;
    colorOut.a = alpha;
    return colorOut;
}

// 主着色器函数
[[ stitchable ]] half4 pathGradientShader(float2 position, device const void *ptr, int size_in_bytes) {
    device const PolylineVertex* polylinePoints = static_cast<device const PolylineVertex*>(ptr);
    int numPoints = size_in_bytes / sizeof(PolylineVertex);

    if (numPoints < 2) {
        return half4(0, 0, 0, 0);
    }

    int closestIndex = 0;
    float closestTVal = 0;
    float minDistance = FLT_MAX;

    // 找到最近的线段
    for (int i = 0; i < (numPoints - 1); i++) {
        float2 A = polylinePoints[i].position;
        float2 B = polylinePoints[i + 1].position;
        LineSegQuery q = distanceToLineSeg(position, A, B);
        if (q.distance < minDistance) {
            closestIndex = i;
            closestTVal = q.tVal;
            minDistance = q.distance;
        }
    }

    // 在两个顶点之间插值颜色
    float4 colorA = polylinePoints[closestIndex].color;
    float4 colorB = polylinePoints[closestIndex + 1].color;
    float4 color = mix(colorA, colorB, closestTVal);
    float4 newColor = convertToPreMultipliedAlpha(color);

    return half4(newColor);
}
