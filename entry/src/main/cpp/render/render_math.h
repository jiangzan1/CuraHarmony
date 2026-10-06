// Minimal 3D math used by the CuraHarmony OpenGL ES preview.

#ifndef CURA_HARMONY_RENDER_MATH_H
#define CURA_HARMONY_RENDER_MATH_H

#include <cmath>

namespace curaharmony
{

struct Vec3
{
    float x{ 0.0F };
    float y{ 0.0F };
    float z{ 0.0F };
};

inline Vec3 operator+(const Vec3 &a, const Vec3 &b)
{
    return Vec3{ a.x + b.x, a.y + b.y, a.z + b.z };
}

inline Vec3 operator-(const Vec3 &a, const Vec3 &b)
{
    return Vec3{ a.x - b.x, a.y - b.y, a.z - b.z };
}

inline Vec3 operator*(const Vec3 &a, const float s)
{
    return Vec3{ a.x * s, a.y * s, a.z * s };
}

inline float dot(const Vec3 &a, const Vec3 &b)
{
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline Vec3 cross(const Vec3 &a, const Vec3 &b)
{
    return Vec3{ a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x };
}

inline Vec3 normalize(const Vec3 &v)
{
    const float length = std::sqrt(dot(v, v));
    if (length <= 1.0e-9F)
    {
        return Vec3{ 0.0F, 0.0F, 1.0F };
    }
    return Vec3{ v.x / length, v.y / length, v.z / length };
}

//! Column-major 4x4 matrix, laid out the way OpenGL expects.
struct Mat4
{
    float m[16]{};

    static Mat4 identity()
    {
        Mat4 result;
        result.m[0] = 1.0F;
        result.m[5] = 1.0F;
        result.m[10] = 1.0F;
        result.m[15] = 1.0F;
        return result;
    }

    static Mat4 translation(const Vec3 &t)
    {
        Mat4 result = identity();
        result.m[12] = t.x;
        result.m[13] = t.y;
        result.m[14] = t.z;
        return result;
    }

    static Mat4 scale(const float s)
    {
        Mat4 result = identity();
        result.m[0] = s;
        result.m[5] = s;
        result.m[10] = s;
        return result;
    }

    static Mat4 perspective(const float fov_y_radians, const float aspect, const float near_plane, const float far_plane)
    {
        Mat4 result;
        const float f = 1.0F / std::tan(fov_y_radians * 0.5F);
        result.m[0] = f / aspect;
        result.m[5] = f;
        result.m[10] = (far_plane + near_plane) / (near_plane - far_plane);
        result.m[11] = -1.0F;
        result.m[14] = (2.0F * far_plane * near_plane) / (near_plane - far_plane);
        return result;
    }

    static Mat4 lookAt(const Vec3 &eye, const Vec3 &center, const Vec3 &up)
    {
        const Vec3 f = normalize(center - eye);
        const Vec3 s = normalize(cross(f, up));
        const Vec3 u = cross(s, f);

        Mat4 result = identity();
        result.m[0] = s.x;
        result.m[4] = s.y;
        result.m[8] = s.z;
        result.m[1] = u.x;
        result.m[5] = u.y;
        result.m[9] = u.z;
        result.m[2] = -f.x;
        result.m[6] = -f.y;
        result.m[10] = -f.z;
        result.m[12] = -dot(s, eye);
        result.m[13] = -dot(u, eye);
        result.m[14] = dot(f, eye);
        return result;
    }
};

inline Mat4 operator*(const Mat4 &a, const Mat4 &b)
{
    Mat4 result;
    for (int column = 0; column < 4; ++column)
    {
        for (int row = 0; row < 4; ++row)
        {
            float sum = 0.0F;
            for (int k = 0; k < 4; ++k)
            {
                sum += a.m[k * 4 + row] * b.m[column * 4 + k];
            }
            result.m[column * 4 + row] = sum;
        }
    }
    return result;
}

} // namespace curaharmony

#endif // CURA_HARMONY_RENDER_MATH_H
