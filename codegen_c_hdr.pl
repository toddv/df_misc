#!/usr/bin/perl

# this script generates C headers from df-structures codegen.out.xml

# input is 1st argument or 'codegen/codegen.out.xml'

# default is generating IDA-compatible headers
# to generate full C headers, use
#  perl codegen --stdc

# to generate linux headers, use
#  perl codegen --linux

use strict;
use warnings;


my $linux = grep { $_ eq '--linux' } @ARGV;
   @ARGV  = grep { $_ ne '--linux' } @ARGV if $linux;

my $stdc = grep { $_ eq '--stdc' } @ARGV;
   @ARGV = grep { $_ ne '--stdc' } @ARGV if $stdc;

my $input = $ARGV[0] || 'codegen/codegen.out.xml';
my $output = $ARGV[1] || 'codegen.h';


use XML::LibXML;

my @lines_full;
our @lines;
my %seen_class;
my %fwd_decl_class;
my %global_types;

sub indent(&) {
    my ($sub) = @_;
    my @lines2;
    {
        local @lines;
        $sub->();
        @lines2 = map { "    " . $_ } @lines;
    }
    push @lines, @lines2;
}

sub fwd_decl_class {
    my ($name) = @_;
    return if ($seen_class{$name});
    return if ($fwd_decl_class{$name});
    $fwd_decl_class{$name} += 1;
    push @lines_full, "struct $name;";
}

my %global_type_renderer = (
    'enum-type' => \&render_global_enum,
    'struct-type' => \&render_global_class,
    'class-type' => \&render_global_class,
    'bitfield-type' => \&render_global_bitfield,
);

my %item_renderer = (
    'global' => \&render_item_global,
    'number' => \&render_item_number,
    'container' => \&render_item_container,
    'compound' => \&render_item_compound,
    'pointer' => \&render_item_pointer,
    'static-array' => \&render_item_staticarray,
    'primitive' => \&render_item_primitive,
    'bytes' => \&render_item_bytes,
);


my %enum_seen;
our $prefix;
sub render_global_enum {
    my ($name, $type) = @_;

    local @lines;
    push @lines, "enum $name {";
    $prefix = $name;
    indent {
        render_enum_fields($type);
    };
    push @lines, "};\n";
    push @lines_full, @lines;
}

sub render_enum_fields {
    my ($type) = @_;

    my $value = 0;
    my $nextvalue = 0;
    for my $item ($type->findnodes('child::enum-item')) {
        $value = $item->getAttribute('value') || $value;
        my $elemname = $item->getAttribute('name'); # || "unk_$value";

        if ($elemname) {
            $elemname = $prefix . '_' . $elemname if (!$stdc);
            $elemname .= '_' while ($enum_seen{$elemname});
            $enum_seen{$elemname} += 1;
            if ($value == $nextvalue) {
                push @lines, "$elemname,";
            } else {
                push @lines, "$elemname = $value,";
            }
            $nextvalue = $value+1;
        }

        $value += 1;
    }

    chop $lines[$#lines] if (@lines);      # remove last coma
}


sub render_global_bitfield {
    my ($name, $type) = @_;

    return if $seen_class{$name};
    $seen_class{$name}++;

    $prefix = $name;
    local @lines;
    push @lines, "struct $name {";
    indent {
        render_bitfield_fields($type);
    };
    push @lines, "};\n";
    push @lines_full, @lines;
}
sub render_bitfield_fields {
    my ($type) = @_;

    if (!$stdc) {
        render_bitfield_as_enum($type);
        render_item_number($type, 'bitfield;');
        return;
    }

    my $shift = 0;
    for my $field ($type->findnodes('child::ld:field')) {
        my $count = $field->getAttribute('count') || 1;
        my $name = $field->getAttribute('name');
        $name = $field->getAttribute('ld:anon-name') || '' if (!$name);
        $name = '_' . $name if !$stdc and $name =~ /^(sub|locret|loc|off|seg|asc|byte|word|dword|qword|flt|dbl|tbyte|stru|algn|unk)_|^effects$/;
        push @lines, "int $name:$count;";
        $shift += $count;
    }
}
sub render_bitfield_as_enum {
    # IDA-only method
    # instead of struct { a:1; b:2; c:1; d:1; }, render enum { a=0x01, c=0x08, d=0x10 };
    my ($type) = @_;
    local @lines;

    push @lines, "enum ${prefix}_enum {";
    indent {
        my $shift = 0;
        for my $item ($type->findnodes('child::ld:field')) {
            my $count = $item->getAttribute('count') || 1;
            my $name = $item->getAttribute('name');
            if ($name) {
                my $val = sprintf('0x%02X', ((2 ** $count - 1) << $shift));
                $name = $prefix . '_' . $name;
                $name .= '_' while ($enum_seen{$name});
                $enum_seen{$name} += 1;
                push @lines, "$name=$val,";
            }
            $shift += $count;
        }
    };
    chop $lines[$#lines] if (@lines);      # remove last coma
    push @lines, "};\n";
    push @lines_full, @lines;
}


sub render_global_class {
    my ($name, $type) = @_;

    # ensure pre-definition of ancestors
    my $parent = $type->getAttribute('inherits-from');
    if ($parent) {
        my $ptype = $global_types{$parent};
        render_global_class($parent, $ptype) if (!$seen_class{$parent});
        $parent = $ptype->getAttribute('original-name') ||
                  $ptype->getAttribute('type-name') ||
                  $parent;
    }

    return if $seen_class{$name};
    $seen_class{$name}++;

    my $rtti_name = $type->getAttribute('original-name') ||
                    $type->getAttribute('type-name') ||
                    $name;
    $seen_class{$rtti_name}++;

    my $has_rtti = ($type->getAttribute('ld:meta') eq 'class-type');

    local $prefix = $name;
    local @lines;

    if ($has_rtti) {
        my $vms = $type->findnodes('child::virtual-methods')->[0];
        if (!$parent) {
            render_class_vtable($name, $vms);
        } elsif ($vms) {
            # composite vtable
            return render_global_class_compositevtable($name, $type, $rtti_name);
        }
    }

    push @lines, "struct $rtti_name {";
    indent {
        if ($parent) {
            push @lines, "struct $parent super;";
        } elsif ($has_rtti) {
            push @lines, "struct vtable_$name *vtable;";
        }
        render_struct_fields($type);
    };
    push @lines, "};\n";

    push @lines_full, @lines;
}
sub render_struct_fields {
    my ($type) = @_;

    for my $field ($type->findnodes('child::ld:field')) {
        my $name = $field->getAttribute('name') ||
                   $field->getAttribute('ld:anon-name');
        $name = '_' . $name if !$stdc and $name and $name =~ /^(sub|locret|loc|off|seg|asc|byte|word|dword|qword|flt|dbl|tbyte|stru|algn|unk)_|^effects$/;
        render_item($field, $name);
        $lines[$#lines] .= ';';
    }
}
sub render_class_vtable {
    my ($name, $vms) = @_;

    push @lines, "struct vtable_$name {";
    indent {
        if ($vms) {
            render_class_vtable_fields($vms);
        } else {
            # ida doesnt like empty structs
            # XXX composite vtable ?
            push @lines, 'void *dummy;' if (!$stdc);
        }
    };
    push @lines, "};";
}
sub render_class_vtable_fields {
    my ($vms) = @_;
    my $voff = 0;
    for my $meth ($vms->findnodes('child::vmethod')) {
        my $name = $meth->getAttribute('name') || $meth->getAttribute('ld:anon-name') || "vmeth_$voff";
        # TODO actual prototype ?
        push @lines, "void *$name;";
        $voff += 4;

        if ($linux and $meth->getAttribute('is-destructor')) {
            # linux destructor has 2 slots
            push @lines, 'void *destructor2;';
            $voff += 4;
        }
    }
}
sub render_global_class_compositevtable {
    my ($name, $type, $rtti_name) = @_;

    my $parent = $type->getAttribute('inherits-from');
    my $ptype = $global_types{$parent};
    $parent = $ptype->getAttribute('original-name') ||
              $ptype->getAttribute('type-name') ||
              $parent;

    my $vms = $type->findnodes('child::virtual-methods')->[0];
    my $parent_vtable = $ptype;

    my $vptype = $ptype;
    while ($vptype && !$vptype->findnodes('child::virtual-methods')->[0])
    {
        my $vp = $vptype->getAttribute('inherits-from');
        $vptype = $global_types{$vp};
    }

    if (!$vptype)
    {
        print "no parent for composite $name\n";
        return
    }
    my $vpname = $vptype->getAttribute('type-name');

    push @lines, "struct vtable_$name {";
    indent {
        push @lines, "struct vtable_$vpname super;";
        render_class_vtable_fields($vms);
    };
    push @lines, "};";

    my @ancestors;
    push @ancestors, $type;
    while ($ptype)
    {
        push @ancestors, $ptype;
        my $p = $ptype->getAttribute('inherits-from');
        $ptype = '';
        $ptype = $global_types{$p} if ($p);
    }

    push @lines, "struct $rtti_name {";
    indent {
        push @lines, "struct vtable_$name *vtable;";

        while ($type = pop(@ancestors))
        {
            if (@ancestors)
            {
                my $aname = $type->getAttribute('type-name');
                # needed to align last field of parent structure
                push @lines, "struct {";
                indent {
                    render_struct_fields($type);
                };
                push @lines, "} $aname;";
            } else {
                render_struct_fields($type);
            }
        }
    };
    push @lines, "};\n";

    push @lines_full, @lines;
}

sub render_global_objects {
    my (@objects) = @_;

    $prefix = 'global';
    local @lines;
    for my $obj (@objects) {
        my $oname = $obj->getAttribute('name');
        my $item = $obj->findnodes('child::ld:item')->[0];
        render_item($item, $oname);
        $lines[$#lines] .= ";\n";
    }
    push @lines_full, @lines;
}


sub render_item {
    my ($item, $name) = @_;
    if (!$item) {
        push @lines, "void";
        $lines[$#lines] .= " $name" if ($name);
        return;
    }

    my $meta = $item->getAttribute('ld:meta');

    my $renderer = $item_renderer{$meta};
    if ($renderer) {
        $renderer->($item, $name);
    } else {
        print "no render item $meta\n";
    }
}

sub render_item_global {
    my ($item, $name) = @_;

    my $typename = $item->getAttribute('type-name');
    my $subtype = $item->getAttribute('ld:subtype');
    my $type = $global_types{$typename};
    my $tname = $type->getAttribute('original-name') ||
    $type->getAttribute('type-name') ||
    $typename;

    if ($subtype and $subtype eq 'enum') {
        #push @lines, "enum $typename $name;";  # this does not handle int16_t enums
        render_item_number($item, $name);
    } else {
        if (!$name or $name !~ /^\*/) {
            my $gtype = $global_types{$typename};
            if ($gtype->getAttribute('ld:meta') eq 'bitfield-type') {
                render_global_bitfield($typename, $global_types{$typename});
            } else {
                render_global_class($typename, $global_types{$typename});
            }
        } else {
            fwd_decl_class($tname);
        }
        push @lines, "struct $tname";
        $lines[$#lines] .= " $name" if ($name);
    }
}

sub render_item_number {
    my ($item, $name) = @_;

    my $subtype = $item->getAttribute('ld:subtype');
    $subtype = $item->getAttribute('base-type') if (!$subtype or $subtype eq 'enum' or $subtype eq 'bitfield');
    $subtype = 'int32_t' if (!$subtype);
    $subtype = 'int8_t' if ($subtype eq 'bool');
    $subtype = 'float' if ($subtype eq 's-float');

    push @lines, "$subtype";
    $lines[$#lines] .= " $name" if ($name);
}

sub render_item_compound {
    my ($item, $name) = @_;

    my $subtype = $item->getAttribute('ld:subtype');
    if (!$subtype || $subtype eq 'bitfield') {
        my $tdef = $item->getAttribute('ld:typedef-name') || 'anon';
        my $sname = $tdef;
        $sname = $prefix . '_' . $sname if $stdc;
        if ($item->getAttribute('is-union')) {
            push @lines, "union {";
        } else {
            push @lines, "struct $sname {";
        }
        indent {
            local $prefix = $sname;
            if (!$subtype) {
                render_struct_fields($item);
            } else {
                render_bitfield_fields($item);
            }
        };
        push @lines, "}";
        $lines[$#lines] .= " $name" if ($name);

    } elsif ($subtype eq 'enum') {
        render_item_number($item, $name);

    } else {
        print "no render compound $subtype\n";
    }
}

sub render_item_container {
    my ($item, $name) = @_;

    my $subtype = $item->getAttribute('ld:subtype');
    $subtype = join('_', split('-', $subtype));
    my $tg = $item->findnodes('child::ld:item')->[0];
    if ($tg) {
        while ($tg->getAttribute('is-union')) {
            $tg = $tg->findnodes('child::ld:field')->[0];
        }
        if ($subtype eq 'stl_vector') {
            my $tgm = $tg->getAttribute('ld:meta');
            # historical_kills/killed_undead
            $tgm = 'number' if ($tgm eq 'compound' and ($tg->getAttribute('ld:subtype')||'') eq 'bitfield');
            if ($tgm eq 'pointer') {
                my $ttg = $tg->findnodes('child::ld:item')->[0];
                if ($ttg and $ttg->getAttribute('ld:meta') eq 'primitive' and $ttg->getAttribute('ld:subtype') eq 'stl-string') {
                    push @lines, 'struct stl_vector_strptr';
                } else {
                    push @lines, 'struct stl_vector_ptr';
                }
            } elsif ($tgm eq 'number') {
                my $tgst = $tg->getAttribute('ld:subtype');
                $tgst = $tg->getAttribute('base-type') if (!$tgst or $tgst eq 'enum' or $tgst eq 'bitfield');
                $tgst = 'int8_t' if $tgst eq 'bool';    # dont confuse with stl-bit-vector
                push @lines, "struct stl_vector_$tgst";
            } elsif ($tgm eq 'global') {
                my $tgt = $global_types{$tg->getAttribute('type-name')};
                my $tgtm = $tgt->getAttribute('ld:meta');
                if ($tgtm eq 'enum-type' or $tgtm eq 'bitfield-type') {
                    my $tgtst = $tgt->getAttribute('base-type') || 'int32_t';
                    push @lines, "struct stl_vector_$tgtst";
                } else {
                    push @lines, "// TODO in $prefix: struct stl_vector_global-$tgtm";
                }
            } elsif ($tgm eq 'compound') {
                my $tgst = $tg->getAttribute('ld:subtype');
                $tgst = $tg->getAttribute('base-type') if (!$tgst or $tgst eq 'enum' or $tgst eq 'bitfield');
                if ($tgst and $tgst =~ /int/) {
                    push @lines, "struct stl_vector_$tgst";
                } else {
                    $tgst ||= '?';
                    push @lines, "// TODO in $prefix: struct stl_vector-compound-$tgst";
                }
            } else {
                push @lines, "// TODO in $prefix: struct stl_vector-$tgm";
            }
        } elsif ($subtype eq 'df_linked_list') {
            push @lines, 'struct df_linked_list';
        } elsif ($subtype eq 'df_array') {
            push @lines, 'struct df_array';
        } elsif ($subtype eq 'stl_deque') {
            push @lines, 'struct stl_deque';
        } else {
            push @lines, "// TODO in $prefix: container $subtype";
        }
    } else {
        if ($subtype eq 'stl_vector') {
            push @lines, 'struct stl_vector_ptr';
        } elsif ($subtype eq 'stl_bit_vector') {
            push @lines, 'struct stl_vector_bool';
        } elsif ($subtype eq 'df_flagarray') {
            push @lines, 'struct df_flagarray';
        } else {
            push @lines, "// TODO in $prefix: container_notg $subtype";
        }
    }
    $lines[$#lines] .= " $name" if ($name);
}

sub render_item_pointer {
    my ($item, $name) = @_;

    my $tg = $item->findnodes('child::ld:item')->[0];
    render_item($tg, "*$name");
}

sub render_item_staticarray {
    my ($item, $name) = @_;

    my $count = $item->getAttribute('count');
    my $tg = $item->findnodes('child::ld:item')->[0];
    if ($name and $name =~ /\*$/) {
        render_item($tg, "*${name}");
    } else {
        render_item($tg, "${name}[$count]");
    }
}

sub render_item_primitive {
    my ($item, $name) = @_;

    my $subtype = $item->getAttribute('ld:subtype');
    if ($subtype eq 'stl-string') {
        push @lines, "struct stl_string";
        $lines[$#lines] .= " $name" if ($name);
    } else {
        print "no render primitive $subtype\n";
    }
}

sub render_item_bytes {
    my ($item, $name) = @_;

    my $subtype = $item->getAttribute('ld:subtype');
    if ($subtype eq 'padding') {
        my $size = $item->getAttribute('size');
        push @lines, "char ${name}[$size]";
    } elsif ($subtype eq 'static-string') {
        my $size = $item->getAttribute('size');
        push @lines, "char ${name}[$size]";
    } else {
        print "no render bytes $subtype\n";
    }
}

my $doc = XML::LibXML->new()->parse_file($input);
$global_types{$_->getAttribute('type-name')} = $_ foreach $doc->findnodes('/ld:data-definition/ld:global-type');

for my $name (sort { $a cmp $b } keys %global_types) {
    my $type = $global_types{$name};
    my $meta = $type->getAttribute('ld:meta');
    my $renderer = $global_type_renderer{$meta};
    if ($renderer) {
        $renderer->($name, $type);
    } else {
        print "no render global type $meta\n";
    }
}

render_global_objects($doc->findnodes('/ld:data-definition/ld:global-object'));

my $hdr = <<EOS;
typedef char      int8_t;
typedef short     int16_t;
typedef int       int32_t;
typedef long long int64_t;
typedef unsigned char      uint8_t;
typedef unsigned short     uint16_t;
typedef unsigned int       uint32_t;
typedef unsigned long long uint64_t;

EOS

my $vecpad = '';

if (!$linux) {
$hdr .= <<EOS;
// Windows STL
struct stl_string {
    union {
        char buf[16];
        char *ptr;
    };
    int32_t len;
    int32_t capa;
    int32_t pad;
};

struct stl_deque {
    void *proxy;
    void *map;
    int32_t map_size;
    int32_t off;
    int32_t size;
    int32_t pad;
};

struct stl_vector_bool {
    char *ptr;
    char *endptr;
    char *endalloc;
    int32_t pad;
    int size;
};

EOS
$vecpad = "    int32_t pad;\n";

} else {
$hdr .= <<EOS;
// Linux Glibc STL
struct stl_string {
    char *ptr;
};

struct stl_deque {
    void *map;
    int32_t size;
    void *start_cur;
    void *start_first;
    void *start_last;
    void *start_map;
    void *end_cur;
    void *end_first;
    void *end_last;
    void *end_map;
};

struct stl_vector_bool {
    uint32_t *ptr;
    int32_t sbit;
    uint32_t *endptr;
    int32_t ebit;
    uint32_t *endalloc;
};

EOS
}

foreach my $vtype ('ptr', 'strptr', 'int32_t', 'uint32_t', 'int16_t', 'uint16_t', 'int8_t', 'uint8_t') {
    my $ctype = $vtype . ' ';
    $ctype = 'void *' if ($vtype eq 'ptr');
    $ctype = 'struct stl_string *' if ($vtype eq 'strptr');

$hdr .= <<EOS;
struct stl_vector_$vtype {
    $ctype*ptr;
    $ctype*endptr;
    $ctype*endalloc;
$vecpad};

EOS
}

$hdr .= <<EOS;
struct df_linked_list {
    void *item;
    void *prev;
    void *next;
};

struct df_array {
    void *ptr;
    uint16_t len;
};

struct df_flagarray {
    uint8_t *ptr;
    uint32_t len;
};
EOS

open FH, ">$output";
print FH $hdr;
print FH "$_\n" for @lines_full;
close FH;

# display warnings
for (@lines_full) {
    print "$_\n" if $_ =~ /TODO/;
}

