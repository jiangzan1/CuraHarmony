// Minimal CSG (constructive solid geometry) on triangle soups, following the BSP algorithm popularised
// by csg.js. Used for the modelling boolean operations (union / subtract / intersect).
//
// Inputs and outputs are interleaved position+normal triangle soups, the same layout the renderer uses.
// Robustness matches csg.js: it is reliable for watertight inputs such as the generated primitives and
// can produce small artefacts on imperfect meshes.

#ifndef CURA_HARMONY_CSG_H
#define CURA_HARMONY_CSG_H

#include <algorithm>
#include <cmath>
#include <memory>
#include <vector>

#include "render_math.h"

namespace curaharmony
{
namespace csg
{

constexpr float EPSILON = 1.0e-5F;

struct Plane
{
    Vec3 normal{};
    float w{ 0.0F };
    bool valid{ false };
};

struct Polygon
{
    std::vector<Vec3> vertices;
    Plane plane;
};

inline Plane planeFromPoints(const Vec3 &a, const Vec3 &b, const Vec3 &c)
{
    const Vec3 n = cross(b - a, c - a);
    const float length = std::sqrt(dot(n, n));
    if (length <= EPSILON)
    {
        return Plane{};
    }
    const Vec3 normal{ n.x / length, n.y / length, n.z / length };
    return Plane{ normal, dot(normal, a), true };
}

inline void flip(Polygon &polygon)
{
    std::reverse(polygon.vertices.begin(), polygon.vertices.end());
    polygon.plane.normal = polygon.plane.normal * -1.0F;
    polygon.plane.w = -polygon.plane.w;
}

inline void splitPolygon(
    const Plane &plane,
    const Polygon &polygon,
    std::vector<Polygon> &coplanar_front,
    std::vector<Polygon> &coplanar_back,
    std::vector<Polygon> &front,
    std::vector<Polygon> &back)
{
    const int COPLANAR = 0;
    const int FRONT = 1;
    const int BACK = 2;
    const int SPANNING = 3;

    int polygon_type = 0;
    std::vector<int> types;
    types.reserve(polygon.vertices.size());
    for (const Vec3 &vertex : polygon.vertices)
    {
        const float distance = dot(plane.normal, vertex) - plane.w;
        const int type = distance < -EPSILON ? BACK : (distance > EPSILON ? FRONT : COPLANAR);
        polygon_type |= type;
        types.push_back(type);
    }

    if (polygon_type == COPLANAR)
    {
        (dot(plane.normal, polygon.plane.normal) > 0.0F ? coplanar_front : coplanar_back).push_back(polygon);
        return;
    }
    if (polygon_type == FRONT)
    {
        front.push_back(polygon);
        return;
    }
    if (polygon_type == BACK)
    {
        back.push_back(polygon);
        return;
    }

    std::vector<Vec3> front_vertices;
    std::vector<Vec3> back_vertices;
    const size_t count = polygon.vertices.size();
    for (size_t i = 0; i < count; ++i)
    {
        const size_t j = (i + 1) % count;
        const int type_i = types[i];
        const int type_j = types[j];
        const Vec3 &vertex_i = polygon.vertices[i];
        const Vec3 &vertex_j = polygon.vertices[j];
        if (type_i != BACK)
        {
            front_vertices.push_back(vertex_i);
        }
        if (type_i != FRONT)
        {
            back_vertices.push_back(vertex_i);
        }
        if ((type_i | type_j) == SPANNING)
        {
            const float t = (plane.w - dot(plane.normal, vertex_i)) / dot(plane.normal, vertex_j - vertex_i);
            const Vec3 crossing = vertex_i + (vertex_j - vertex_i) * t;
            front_vertices.push_back(crossing);
            back_vertices.push_back(crossing);
        }
    }
    if (front_vertices.size() >= 3)
    {
        front.push_back(Polygon{ front_vertices, polygon.plane });
    }
    if (back_vertices.size() >= 3)
    {
        back.push_back(Polygon{ back_vertices, polygon.plane });
    }
}

struct Node
{
    Plane plane;
    std::vector<Polygon> polygons;
    std::unique_ptr<Node> front;
    std::unique_ptr<Node> back;

    void build(const std::vector<Polygon> &list)
    {
        if (list.empty())
        {
            return;
        }
        if (! plane.valid)
        {
            plane = list[0].plane;
        }
        std::vector<Polygon> front_list;
        std::vector<Polygon> back_list;
        for (const Polygon &polygon : list)
        {
            splitPolygon(plane, polygon, polygons, polygons, front_list, back_list);
        }
        if (! front_list.empty())
        {
            if (! front)
            {
                front = std::make_unique<Node>();
            }
            front->build(front_list);
        }
        if (! back_list.empty())
        {
            if (! back)
            {
                back = std::make_unique<Node>();
            }
            back->build(back_list);
        }
    }

    void invert()
    {
        for (Polygon &polygon : polygons)
        {
            flip(polygon);
        }
        plane.normal = plane.normal * -1.0F;
        plane.w = -plane.w;
        if (front)
        {
            front->invert();
        }
        if (back)
        {
            back->invert();
        }
        std::swap(front, back);
    }

    std::vector<Polygon> clipPolygons(const std::vector<Polygon> &list) const
    {
        if (! plane.valid)
        {
            return list;
        }
        std::vector<Polygon> front_list;
        std::vector<Polygon> back_list;
        for (const Polygon &polygon : list)
        {
            splitPolygon(plane, polygon, front_list, back_list, front_list, back_list);
        }
        if (front)
        {
            front_list = front->clipPolygons(front_list);
        }
        if (back)
        {
            back_list = back->clipPolygons(back_list);
        }
        else
        {
            back_list.clear();
        }
        front_list.insert(front_list.end(), back_list.begin(), back_list.end());
        return front_list;
    }

    void clipTo(const Node &other)
    {
        polygons = other.clipPolygons(polygons);
        if (front)
        {
            front->clipTo(other);
        }
        if (back)
        {
            back->clipTo(other);
        }
    }

    void allPolygons(std::vector<Polygon> &out) const
    {
        out.insert(out.end(), polygons.begin(), polygons.end());
        if (front)
        {
            front->allPolygons(out);
        }
        if (back)
        {
            back->allPolygons(out);
        }
    }
};

inline std::vector<Polygon> polygonsFromVertices(const std::vector<float> &vertices)
{
    std::vector<Polygon> polygons;
    for (size_t i = 0; i + 17 < vertices.size(); i += 18)
    {
        const Vec3 a{ vertices[i], vertices[i + 1], vertices[i + 2] };
        const Vec3 b{ vertices[i + 6], vertices[i + 7], vertices[i + 8] };
        const Vec3 c{ vertices[i + 12], vertices[i + 13], vertices[i + 14] };
        const Plane plane = planeFromPoints(a, b, c);
        if (! plane.valid)
        {
            continue;
        }
        polygons.push_back(Polygon{ { a, b, c }, plane });
    }
    return polygons;
}

inline std::vector<float> verticesFromPolygons(const std::vector<Polygon> &polygons)
{
    std::vector<float> out;
    for (const Polygon &polygon : polygons)
    {
        for (size_t i = 2; i < polygon.vertices.size(); ++i)
        {
            const Vec3 &a = polygon.vertices[0];
            const Vec3 &b = polygon.vertices[i - 1];
            const Vec3 &c = polygon.vertices[i];
            const Vec3 normal = normalize(cross(b - a, c - a));
            const Vec3 corners[3] = { a, b, c };
            for (const Vec3 &vertex : corners)
            {
                out.insert(out.end(), { vertex.x, vertex.y, vertex.z, normal.x, normal.y, normal.z });
            }
        }
    }
    return out;
}

enum class Operation
{
    Union,
    Subtract,
    Intersect,
};

// Applies `op` to two triangle soups and returns the resulting triangle soup.
inline std::vector<float> apply(const Operation op, const std::vector<float> &a_vertices, const std::vector<float> &b_vertices)
{
    Node a;
    Node b;
    a.build(polygonsFromVertices(a_vertices));
    b.build(polygonsFromVertices(b_vertices));

    std::vector<Polygon> extra;
    if (op == Operation::Union)
    {
        a.clipTo(b);
        b.clipTo(a);
        b.invert();
        b.clipTo(a);
        b.invert();
    }
    else if (op == Operation::Subtract)
    {
        a.invert();
        a.clipTo(b);
        b.clipTo(a);
        b.invert();
        b.clipTo(a);
        b.invert();
    }
    else
    {
        a.invert();
        b.clipTo(a);
        b.invert();
        a.clipTo(b);
        b.clipTo(a);
    }
    b.allPolygons(extra);
    a.build(extra);
    if (op == Operation::Subtract || op == Operation::Intersect)
    {
        a.invert();
    }

    std::vector<Polygon> result;
    a.allPolygons(result);
    return verticesFromPolygons(result);
}

} // namespace csg
} // namespace curaharmony

#endif // CURA_HARMONY_CSG_H
