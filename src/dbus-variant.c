/*
 * D-Bus Variants
 */

#include <c-macro.h>
#include <stdlib.h>
#include "dbus-variant.h"

_Static_assert(DBUS_VARIANT_TYPE_LENGTH_MAX * 8 < (1 << DBUS_VARIANT_TYPE_SIZE_BITS),
               "Not enough bits available to fixed-size types");
_Static_assert(sizeof(DBusVariantType) == 2,
               "Unexpected padding in DBusVariantType");

const DBusVariantType dbus_variant_type_builtins[256] = {
        ['b'] = { C_EXPAND(DBUS_VARIANT_TYPE_b), 1 },
        ['y'] = { C_EXPAND(DBUS_VARIANT_TYPE_y), 1 },
        ['n'] = { C_EXPAND(DBUS_VARIANT_TYPE_n), 1 },
        ['q'] = { C_EXPAND(DBUS_VARIANT_TYPE_q), 1 },
        ['i'] = { C_EXPAND(DBUS_VARIANT_TYPE_i), 1 },
        ['u'] = { C_EXPAND(DBUS_VARIANT_TYPE_u), 1 },
        ['x'] = { C_EXPAND(DBUS_VARIANT_TYPE_x), 1 },
        ['t'] = { C_EXPAND(DBUS_VARIANT_TYPE_t), 1 },
        ['h'] = { C_EXPAND(DBUS_VARIANT_TYPE_h), 1 },
        ['d'] = { C_EXPAND(DBUS_VARIANT_TYPE_d), 1 },
        ['s'] = { C_EXPAND(DBUS_VARIANT_TYPE_s), 1 },
        ['o'] = { C_EXPAND(DBUS_VARIANT_TYPE_o), 1 },
        ['g'] = { C_EXPAND(DBUS_VARIANT_TYPE_g), 1 },
        ['v'] = { C_EXPAND(DBUS_VARIANT_TYPE_v), 1 },
};

/**
 * dbus_variant_type_new_from_signature() - XXX
 */
long dbus_variant_type_new_from_signature(DBusVariantType **infop,
                                          const char *signature,
                                          size_t n_signature) {
        _c_cleanup_(c_freep) DBusVariantType *info = NULL;
        DBusVariantType *container, *this;
        const DBusVariantType *builtin;
        DBusVariantType *stack[DBUS_VARIANT_TYPE_DEPTH_MAX];
        size_t i, i_container, n_type, depth;
        char c;

        /* reject overlong signatures right away */
        if (n_signature > DBUS_VARIANT_TYPE_LENGTH_MAX)
                return -EBADRQC;

        /*
         * As a first step, figure out how long the next type in @signature is.
         * This requires iterating the entire type, counting opening/closing
         * brackets. We do this up-front, with only limited type validation.
         * Knowing the final type-size allows pre-allocating @info.
         *
         * Note that empty signatures will be rejected by this. The caller is
         * responsible to check for empty signatures, otherwise you might end
         * up in infinite loops.
         */
        for (n_type = 0, depth = 0; n_type < n_signature; ++n_type) {
                if (signature[n_type] == 'a') {
                        continue;
                } else if (signature[n_type] == '(' ||
                           signature[n_type] == '{') {
                        ++depth;
                } else if (signature[n_type] == ')' ||
                           signature[n_type] == '}') {
                        if (!depth--)
                                return -EBADRQC;
                }

                if (!depth)
                        break;
        }

        if (n_type >= n_signature)
                return -EBADRQC;

        /*
         * Now that we know the type length, we pre-allocate @info and fill it
         * in.
         */
        info = malloc(sizeof(*info) * n_type);
        if (!info)
                return -ENOMEM;

        depth = 0;
        container = NULL;

        for (i = 0, depth = 0; i < n_type; ++i) {
                c = signature[i];
                this = &info[i];
                builtin = &dbus_variant_type_builtins[(uint8_t)c];
                i_container = container ? (container - info) : 0;

                /*
                 * In case our surrounding container is a DICT, we need to make
                 * sure that the _first_ following type is basic, and there are
                 * exactly 2 types following.
                 */
                if (container && signature[i_container] == '{') {
                        if (i_container + 2 > i) {
                                /* first type must be basic */
                                if (_c_unlikely_(!builtin->basic))
                                        return -EBADRQC;
                        } else if (i_container + 2 == i) {
                                /* there must be a second type */
                                if (_c_unlikely_(c == '}'))
                                        return -EBADRQC;
                        } else if (i_container + 2 < i) {
                                /* DICT is closed after second type */
                                if (_c_unlikely_(c != '}'))
                                        return -EBADRQC;
                        }
                }

                switch (c) {
                case '(':
                case '{':
                case 'a':
                        /* validate maximum depth */
                        if (_c_unlikely_(depth >= C_ARRAY_SIZE(stack)))
                                return -EBADRQC;

                        this->size = (c != 'a');
                        this->alignment = 0;
                        this->basic = 0;
                        this->valid = 1;

                        /*
                         * We opened a new container type, so continue with the
                         * next character. Skip handling terminal types below.
                         */
                        stack[depth++] = this;
                        container = this;
                        continue;

                case '}':
                case ')':
                        if (_c_unlikely_(!container ||
                                         signature[i_container] != ((c == '}') ? '{' : '(')))
                                return -EBADRQC;

                        *this = (DBusVariantType){ };
                        this = container;
                        container = --depth ? stack[depth - 1] : NULL;
                        break;

                default:
                        /* validate type existence */
                        if (_c_unlikely_(!builtin->valid))
                                return -EBADRQC;

                        break;
                }

                while (depth > 0 && signature[i_container] == 'a') {
                        /* arrays inherit alignment of their child */
                        container->alignment = (container + 1)->alignment;

                        this = container;
                        container = --depth ? stack[depth - 1] : NULL;
                }

                if (depth > 0) {
                        if (container->size && this->size) {
                                container->size = C_ALIGN_TO(container->size, 1 << this->alignment);
                                container->size += this->size;
                                /* subtract initializer */
                                container->size -= (this == container + 1);
                        } else {
                                container->size = 0;
                        }

                        container->alignment = C_MAX(container->alignment, this->alignment);
                }

                if (!depth) {
                        *infop = info;
                        info = NULL;
                        return n_type;
                }
        }

        return -EBADRQC;
}
