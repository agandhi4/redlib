//! The one pooled HTTP transport with a randomized browser fingerprint. It sits below
//! everything that talks to Reddit (oauth_device, client, media_proxy, main's GitHub fetches)
//! and imports none of them, which keeps the module graph one-way.
use log::info;
use std::sync::LazyLock;
use wreq::redirect::Policy;
use wreq::{Client as WreqClient, EmulationFactory};
use wreq_util::{Emulation, EmulationOS, EmulationOption};

pub static CLIENT: LazyLock<WreqClient> = LazyLock::new(build_client);

pub fn build_client() -> WreqClient {
	// Keeping this list short to aid in privacy.
	// The more emulations, the more unique a fingerprint each instance has.
	// But some emulations should increase evasiveness.
	let emulation = [Emulation::Chrome145, Emulation::Firefox147];
	let emulation_os = [EmulationOS::Android, EmulationOS::Windows];

	let rand = fastrand::usize(..);
	let emulation = EmulationOption::builder()
		.emulation(emulation[rand % emulation.len()])
		.emulation_os(emulation_os[rand % emulation_os.len()])
		.build()
		.emulation();

	info!("Building Wreq client with random emulation {:?}", emulation);
	WreqClient::builder()
		.emulation(emulation)
		.redirect(Policy::none())
		.build()
		.expect("Should always be able to build a client")
}
