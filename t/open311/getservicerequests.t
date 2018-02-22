#!/usr/bin/env perl

use FixMyStreet::TestMech;

use_ok( 'Open311' );
use_ok( 'Open311::GetServiceRequests' );
use DateTime;
use DateTime::Format::W3CDTF;

my $mech = FixMyStreet::TestMech->new;

my $user = $mech->create_user_ok('system_user@example.com', name => 'test users');
my $body = $mech->create_body_ok(2482, 'Bromley');
my $contact = $mech->create_contact_ok( body_id => $body->id, category => 'sidewalks', email => 'sidewalks@example.com' );

my $dtf = DateTime::Format::W3CDTF->new;

my $requests_xml = qq{<?xml version="1.0" encoding="utf-8"?>
<service_requests>
<request>
<service_request_id>638344</service_request_id>
<status>open</status>
<status_notes>This is a note.</status_notes>
<service_name>Sidewalk and Curb Issues</service_name>
<service_code>sidewalks</service_code>
<description>This is a sidewalk problem</description>
<agency_responsible></agency_responsible>
<service_notice></service_notice>
<requested_datetime>2010-04-14T06:37:38-08:00</requested_datetime>
<updated_datetime>2010-04-14T06:37:38-08:00</updated_datetime>
<expected_datetime>2010-04-15T06:37:38-08:00</expected_datetime>
<lat>51.4021</lat>
<long>0.01578</long>
</request>
<request>
<service_request_id>638345</service_request_id>
<status>investigating</status>
<status_notes>This is a for a different issue.</status_notes>
<service_name>Not Sidewalk and Curb Issues</service_name>
<service_code>not_sidewalks</service_code>
<description>This is a problem</description>
<agency_responsible></agency_responsible>
<service_notice></service_notice>
<requested_datetime>2010-04-15T06:37:38-08:00</requested_datetime>
<updated_datetime>2010-04-15T06:37:38-08:00</updated_datetime>
<expected_datetime>2010-04-15T06:37:38-08:00</expected_datetime>
<lat>51.4021</lat>
<long>0.01578</long>
</request>
</service_requests>
};

my $o = Open311->new(
    jurisdiction => 'mysociety',
    endpoint => 'http://example.com',
    test_mode => 1,
    test_get_returns => { 'requests.xml' => $requests_xml }
);

subtest 'basic parsing checks' => sub {
    my $update = Open311::GetServiceRequests->new( system_user => $user );
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
    }, sub {
        $update->create_problems( $o, $body );
    };

    my $p1_date = $dtf->parse_datetime('2010-04-14T06:37:38-08:00')
                    ->set_time_zone(
                        FixMyStreet->time_zone || FixMyStreet->local_time_zone
                  );

    my $p = FixMyStreet::DB->resultset('Problem')->search(
                { external_id => 638344 }
            )->first;

    ok $p, 'Found problem';
    is $p->detail, 'This is a sidewalk problem', 'correct problem description';
    is $p->created, $p1_date, 'Problem has correct creation date';
    is $p->confirmed, $p1_date, 'Problem has correct confirmed date';
    is $p->whensent, $p1_date, 'Problem has whensent set';
    is $p->state, 'confirmed', 'correct problem state';
    is $p->user->id, $user->id, 'user set to system user';
    is $p->category, 'sidewalks', 'correct problem category';

    my $p2 = FixMyStreet::DB->resultset('Problem')->search( { external_id => 638345 } )->first;
    ok $p2, 'second problem found';
    ok $p2->whensent, 'second problem marked sent';
    is $p2->state, 'investigating', 'second problem correct state';
    is $p2->category, 'Other', 'category falls back to Other';
};

subtest 'check problems not re-created' => sub {
    my $update = Open311::GetServiceRequests->new( system_user => $user );
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
    }, sub {
        $update->create_problems( $o, $body );
    };

    my $count = FixMyStreet::DB->resultset('Problem')->count;

    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
    }, sub {
        $update->create_problems( $o, $body );
    };

    my $after_count = FixMyStreet::DB->resultset('Problem')->count;

    is $count, $after_count, "problems not re-created";
};

for my $test (
  {
      desc => 'problem with no id is not created',
      detail => 'This is a problem with no service_code',
      subs => { id => '', desc => 'This is a problem with service code' },
  },
  {
      desc => 'problem with no lat is not created',
      detail => 'This is a problem with no lat',
      subs => { lat => '', desc => 'This is a problem with no lat' },
  },
  {
      desc => 'problem with no long is not created',
      detail => 'This is a problem with no long',
      subs => { long => '', desc => 'This is a problem with no long' },
  },
  {
      desc => 'problem with bad lat/long is not created',
      detail => 'This is a problem with bad lat/long',
      subs => { lat => '51', long => 0.1, desc => 'This is a problem with bad lat/long' },
  },
) {
    subtest $test->{desc} => sub {
        my $xml = prepare_xml( $test->{subs} );
        my $o = Open311->new(
            jurisdiction => 'mysociety',
            endpoint => 'http://example.com',
            test_mode => 1,
            test_get_returns => { 'requests.xml' => $xml}
        );

        my $count = FixMyStreet::DB->resultset('Problem')->count;
        my $update = Open311::GetServiceRequests->new( system_user => $user );
        FixMyStreet::override_config {
            MAPIT_URL => 'http://mapit.uk/',
        }, sub {
            $update->create_problems( $o, $body );
        };
        my $after_count = FixMyStreet::DB->resultset('Problem')->count;

        warn $count;
        is $count, $after_count, "problems not created";

        my $with_text = FixMyStreet::DB->resultset('Problem')->search( {
              detail => $test->{detail}
        } )->count;

        is $with_text, 0, 'no matching problem created';
    };
}

sub prepare_xml {
    my $replacements = shift;

    my %defaults = (
        desc => 'this is a problem',
        lat => 51.4021,
        long => 0.01578,
        id => 123456,
        %$replacements
    );

    my $xml = qq[<?xml version="1.0" encoding="utf-8"?>
<service_requests>
<request>
<service_request_id>XXX_ID</service_request_id>
<status>open</status>
<status_notes></status_notes>
<service_name>Sidewalk and Curb Issues</service_name>
<service_code>sidewalks</service_code>
<description>XXX_DESC</description>
<agency_responsible></agency_responsible>
<service_notice></service_notice>
<requested_datetime>2010-04-14T06:37:38-08:00</requested_datetime>
<updated_datetime>2010-04-14T06:37:38-08:00</updated_datetime>
<expected_datetime>2010-04-15T06:37:38-08:00</expected_datetime>
<lat>XXX_LAT</lat>
<long>XXX_LONG</long>
</request>
</service_requests>
];

    for my $key (keys %defaults) {
        my $string = 'XXX_' . uc $key;
        $xml =~ s/$string/$defaults{$key}/;
    }

    return $xml;
}

done_testing();
